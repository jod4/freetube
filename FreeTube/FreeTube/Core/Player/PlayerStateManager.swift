import Foundation
import AVFoundation
import Combine
import Kingfisher
import OSLog
import SwiftData
import UIKit

/// CLAUDE.md §8: single source of truth for playback. Injected via SwiftUI environment.
/// Mini player and full-screen player both observe this object — neither owns its own `AVPlayer`.
///
/// Combine is used **only** here for `AVPlayer` time-observer bridging, per CLAUDE.md §2.9.
@available(iOS 17.0, *)
@MainActor
@Observable
final class PlayerStateManager {
    enum LoadState: Equatable {
        case idle
        case resolving
        /// File is being fetched. `progress` is 0…1 when known, nil during yt-dlp's mux/merge phase.
        /// `phase` labels which stream is in flight ("video", "audio", "stream") so the UI can show
        /// "Downloading video 42%" instead of two confusing identical bars in a row.
        case downloading(progress: Double?, phase: String?)
        case readyToPlay
        case failed(String)
    }

    // MARK: - Published state

    private(set) var currentVideo: Video?
    /// Cached artwork for the current video. Used both to populate `MPNowPlayingInfoCenter`
    /// (lock-screen + Control Center) and (in the future) any in-app UI that wants a UIImage rather
    /// than the SwiftUI `Image`. Refreshed when the current video changes.
    private(set) var currentArtwork: UIImage?
    private(set) var loadState: LoadState = .idle
    private(set) var isPlaying: Bool = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var miniPlayerVisible: Bool = false
    var fullScreenPresented: Bool = false

    // MARK: - AVPlayer

    /// `AVQueuePlayer` to unlock `advanceToNextItem()` and queue introspection for future preload.
    /// IMPORTANT: don't use `replaceCurrentItem(with:)` to load tracks — it's a no-op on
    /// `AVQueuePlayer` when the internal queue is empty (which is our usual state). Use the
    /// `removeAllItems()` + `insert(_:after:)` pattern via `swap(to:)` below.
    let player = AVQueuePlayer()

    // MARK: - Collaborators

    let queue: QueueManager
    private let resolver: any PlaybackResolving
    private let preferences: UserPreferences
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "PlayerStateManager")

    /// Sticky "this queue is endless" intent. Set to `true` whenever the user loads a video
    /// without explicitly skipping recommendations (Home / Search / Mini-player / row taps),
    /// and `false` for curated batch actions like playlist's Play all / Shuffle all. Drives:
    ///   1. The per-load `fillQueueWithRecommendations` call in `resolveAndPlay`.
    ///   2. The auto-advance dead-end recovery in `playNext()` — when the queue runs out and
    ///      repeat is off, we fire a fresh recs fetch using the queue's last item as a seed,
    ///      then advance once new items land. That gives the requested "endless queue" feel:
    ///      whenever you reach the latest item, recommendations refill behind it.
    private var queueAcceptsRecommendations = true

    private var timeObserver: Any?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemErrorLogObservation: NSObjectProtocol?
    private var itemAccessLogObservation: NSObjectProtocol?
    private var playerErrorObservation: NSKeyValueObservation?
    private var defaultRateObservation: NSKeyValueObservation?
    /// The item currently playing from a remote stream (nil for local files). Lets
    /// `handleStreamFailure` fall back to a download exactly once per stream, and only for
    /// the item that's actually current.
    private var streamedItem: AVPlayerItem?
    init(
        queue: QueueManager = QueueManager(),
        resolver: any PlaybackResolving = PlaybackResolver(),
        preferences: UserPreferences = UserPreferences()
    ) {
        self.queue = queue
        self.resolver = resolver
        self.preferences = preferences
        // Keep the audio track running when the player view goes off-screen (popup minimize, app
        // backgrounded). Without this, AVPlayer pauses video tracks as soon as their pixel buffer
        // pipeline is no longer visible, which manifests as "audio cuts out the moment you collapse
        // the mini-player." Pairs with the `.playback` AVAudioSession configured at launch.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Restore the last-used playback speed. `defaultRate` is what `AVPlayerViewController`'s
        // speed menu writes, and `AVPlayer.play()` resumes at this rate (not the transient `rate`).
        // Setting it *before* installObservers keeps the KVO from firing back and re-saving the
        // same value during launch.
        player.defaultRate = Float(preferences.playbackRate)
        installObservers()
    }

    /// Tear-down hook for tests / app lifecycle. Call before releasing the manager. We avoid `deinit`
    /// here so we don't have to reach into main-actor-isolated state from a nonisolated context.
    func tearDownObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
    }

    // MARK: - Public commands

    /// Loads a video for playback.
    ///
    /// - Parameter skipRecommendations: when `true`, suppresses the post-play "fill queue with
    ///   YouTube recommendations" call. Pass this from explicit batch actions that already
    ///   populated a curated queue — playlist's Play all / Shuffle all — so the user's queue
    ///   stays exactly what they chose. Default is `false` so single-video taps from Home /
    ///   Search / Mini-player still get the YouTube-app-style autoplay chain.
    /// Play a local file already on disk — used by the **Link** tab's completed downloads.
    ///
    /// **Why a separate entry point and not `load(video:)`:** the YouTube-shaped resolver in
    /// `resolveAndPlay` calls `DownloadManager.ensureDownloaded` which keys off `videoID` and
    /// looks for `Documents/<id>.mp4`. URL-fetched files live under `Documents/<title>.mp4`
    /// and don't have a YouTube `videoID`, so threading them
    /// through the normal path would either crash or silently re-trigger a yt-dlp download.
    /// This method skips resolution entirely — the file is already there, just play it.
    ///
    /// **What we skip vs the normal load path:** watch-history upsert (URL files aren't in
    /// the YouTube `WatchHistoryEntry` schema), queue recommendation fill (no related-video
    /// surface for arbitrary URLs), and `ensureDownloaded` (file is on disk).
    /// **What we keep:** `currentVideo` (synthetic so the mini-player title/subtitle still
    /// render), `miniPlayerVisible` flipped true so LNPopupUI shows the bar, NowPlayingCenter
    /// update for lock-screen artwork, and the standard observe/loadItem flow so errors and
    /// playback state still surface through the existing UI.
    func loadLocalFile(at fileURL: URL, title: String, source: String?, thumbnailURL: URL?) {
        log.info("loadLocalFile path=\(fileURL.path, privacy: .public) title=\"\(title, privacy: .public)\"")
        if isPlaying { pause() }
        if !player.items().isEmpty { player.removeAllItems() }

        // Synthetic Video so the existing mini-player + FullScreenPlayer chrome (which read
        // `currentVideo` everywhere) work without conditional branches. Channel name reuses
        // the extractor ("YouTube", "Vimeo", …) — closest analogue for arbitrary URLs.
        let synthetic = Video(
            id: "fetch-" + UUID().uuidString,
            title: title,
            channelID: "",
            channelName: source ?? "Link",
            channelThumbnailURL: nil,
            thumbnailURL: thumbnailURL,
            duration: nil,
            viewCount: nil,
            publishedAt: nil,
            descriptionSnippet: nil,
            isLive: false,
            isShort: false
        )
        currentVideo = synthetic
        // Bypass the queue's YouTube-related tracking — URL files don't participate in the
        // recommendation chain. setCurrent appends to the queue dataset for upcoming-up UI;
        // we just zero it for arbitrary files.
        queueAcceptsRecommendations = false
        presentFullScreen()
        elapsed = 0
        duration = 0
        refreshArtwork(for: synthetic)

        let item = AVPlayerItem(url: fileURL)
        loadItem(item)
        loadState = .readyToPlay
        updateNowPlaying()
        play()
    }

    /// - Parameter presentFullScreen: open the expanded player (default — the user tapped a
    ///   video and wants to watch it). `false` for queue advances (Next / Previous /
    ///   auto-advance), which keep whatever presentation the user chose.
    func load(_ video: Video, autoplay: Bool = true, skipRecommendations: Bool = false, presentFullScreen: Bool = true) {
        log.info("load(\(video.id, privacy: .public)) autoplay=\(autoplay, privacy: .public) skipRecs=\(skipRecommendations, privacy: .public)")
        queueAcceptsRecommendations = !skipRecommendations
        // Pause and tear down anything currently playing. Otherwise we'd keep streaming audio from
        // the previous video while the new one's file is downloading — which is what the user kept
        // hearing when they tapped "next" mid-download.
        if isPlaying {
            log.info("load: pausing current playback before resolving new video")
            pause()
        }
        if !player.items().isEmpty {
            log.debug("load: clearing AVQueuePlayer items (\(self.player.items().count, privacy: .public) entries)")
            player.removeAllItems()
        }
        streamedItem = nil
        currentVideo = video
        // Keep the queue coherent. Fresh taps from search/home append the video; subsequent calls
        // from `playNext()` / `playPrevious()` find it already there and just update `currentIndex`.
        queue.setCurrent(video)
        if presentFullScreen {
            self.presentFullScreen()
        } else {
            miniPlayerVisible = true
        }
        loadState = .resolving
        // Wipe transport state from the previous video so a stray time-observer tick during the
        // transition (the periodic callback can fire AFTER currentVideo flips but BEFORE the new
        // AVPlayerItem is installed) doesn't carry the old item's elapsed/duration into a save —
        // that's what showed phantom progress bars on cells the user never played.
        elapsed = 0
        duration = 0
        recordWatchHistory(video: video)
        refreshArtwork(for: video)
        Task { await resolveAndPlay(video: video, autoplay: autoplay, skipRecommendations: skipRecommendations) }
    }

    private var progressObservationTask: Task<Void, Never>?

    /// Polls `DownloadManager.shared.progressByVideoID` and updates `loadState` so the UI sees a
    /// live progress bar while the file is downloading. Until a stream transfer has actually
    /// started (`phaseByVideoID` has an entry) the state stays `.resolving` ("Preparing…") —
    /// yt-dlp's extraction + JS challenge solving takes 10+ s before the first byte, and showing
    /// "Downloading 0%" for that whole time looked like a hang. The dictionary updates synchronously via
    /// `@Observable`, but we still need an explicit poll loop because `loadState` lives on the
    /// player and SwiftUI views don't observe `DownloadManager` from this file's call site.
    private func startProgressObservation(for videoID: String) {
        progressObservationTask?.cancel()
        progressObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let progress = DownloadManager.shared.progressByVideoID[videoID]
                let phase = DownloadManager.shared.phaseByVideoID[videoID]
                switch self.loadState {
                case .resolving, .downloading:
                    let next: LoadState = phase == nil
                        ? .resolving
                        : .downloading(progress: progress, phase: phase)
                    if next != self.loadState { self.loadState = next }
                default:
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func stopProgressObservation() {
        progressObservationTask?.cancel()
        progressObservationTask = nil
    }

    /// Upserts a `WatchHistoryEntry` so the Library's "Recents" section reflects what the user
    /// played. Same-id taps just bump `watchedAt` so the row floats to the top. The actor hop keeps
    /// the SQL write off the main thread; @Query observers see the change automatically once the
    /// background context saves.
    private func recordWatchHistory(video: Video) {
        guard preferences.saveWatchHistory else { return }
        let videoID = video.id
        let title = video.title
        let channelName = video.channelName
        let thumbnailURL = video.thumbnailURL
        Task {
            await PersistenceWriter.shared.upsertWatchHistory(
                videoID: videoID,
                title: title,
                channelName: channelName,
                thumbnailURL: thumbnailURL
            )
        }
    }

    func play() {
        log.info("play()")
        player.play()
        isPlaying = true
    }

    func pause() {
        log.info("pause()")
        player.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        log.info("togglePlayPause() (isPlaying=\(self.isPlaying, privacy: .public))")
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        log.info("seek(to: \(seconds, privacy: .public)s)")
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seekRelative(by delta: TimeInterval) {
        log.info("seekRelative(by: \(delta, privacy: .public)s)")
        seek(to: max(0, min(elapsed + delta, duration)))
    }

    func playNext() {
        log.info("playNext() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        if let next = queue.advance() {
            load(next, presentFullScreen: false)
            return
        }
        // Queue at end. If this queue accepts recommendations and the user hasn't asked for
        // repeat-all/repeat-one, refill from the last item's recommendations and try advancing
        // again — that's the "endless queue" behavior: every time we hit the bottom, more recs
        // refill behind us.
        guard queueAcceptsRecommendations,
              queue.repeatMode == .off,
              let seed = queue.items.last else {
            log.notice("playNext: queue at end, no recs refill (acceptsRecs=\(self.queueAcceptsRecommendations, privacy: .public), repeat=\(String(describing: self.queue.repeatMode), privacy: .public))")
            return
        }
        log.info("playNext: queue at end, refilling recs from seed=\(seed.id, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            let countBefore = self.queue.items.count
            await self.fillQueueWithRecommendations(for: seed)
            guard self.queue.items.count > countBefore else {
                self.log.notice("playNext: refill produced no new items, giving up")
                return
            }
            if let next = self.queue.advance() {
                self.load(next, presentFullScreen: false)
            }
        }
    }

    func playPrevious() {
        log.info("playPrevious() — queue size=\(self.queue.items.count, privacy: .public) currentIndex=\(self.queue.currentIndex, privacy: .public)")
        guard let previous = queue.previous() else {
            log.notice("playPrevious: at start of queue, nothing to go back to")
            return
        }
        load(previous, presentFullScreen: false)
    }

    func dismiss() {
        log.info("dismiss()")
        pause()
        miniPlayerVisible = false
        fullScreenPresented = false
        currentVideo = nil
        loadState = .idle
        streamedItem = nil
        player.removeAllItems()
        NowPlayingCenter.clear()
    }

    // MARK: - Internals

    /// Shows the popup bar and expands it into the full-screen player. When the bar isn't up
    /// yet, LNPopupUI needs it presented before it can open — so open on the next beat.
    /// Opening early also matters for quality: AVPlayer picks HLS variants by the size of
    /// the visible video layer, so a stream started in the tiny mini bar begins (and
    /// pre-buffers) at the lowest variant.
    private func presentFullScreen() {
        guard !miniPlayerVisible else {
            fullScreenPresented = true
            return
        }
        miniPlayerVisible = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.miniPlayerVisible, self.currentVideo != nil else { return }
            self.fullScreenPresented = true
        }
    }

    /// Swap the player to a new item using the `AVQueuePlayer`-correct pattern. `replaceCurrentItem`
    /// is documented to be a no-op when the player's internal queue is empty (which is our usual
    /// state since the playable URL is short-lived and we never preload), so we always tear the
    /// queue down to nothing first and then insert. Also wires KVO so we hear about decode/auth
    /// failures the moment they happen (CoreMedia's `CFByteFlume err=-12939` style messages don't
    /// surface a structured `NSError` otherwise).
    private func loadItem(_ item: AVPlayerItem) {
        let url = (item.asset as? AVURLAsset)?.url.path ?? "(non-URL asset)"
        log.info("loadItem: removeAllItems + insert (asset=\(url, privacy: .public))")
        player.removeAllItems()
        player.insert(item, after: nil)
        log.debug("loadItem: queue size after insert=\(self.player.items().count, privacy: .public)")
        observe(item: item)
    }

    private func observe(item: AVPlayerItem) {
        itemStatusObservation?.invalidate()
        if let token = itemErrorLogObservation { NotificationCenter.default.removeObserver(token) }
        if let token = itemAccessLogObservation { NotificationCenter.default.removeObserver(token) }

        // One line per HLS variant switch: which rendition AVPlayer is actually playing and
        // the throughput it measured. Diagnoses "stream looks like 360p" reports.
        itemAccessLogObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let item, let event = item.accessLog()?.events.last else { return }
            let size = item.presentationSize
            self?.log.info("AVPlayerItem access-log: \(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) indicated=\(Int(event.indicatedBitrate / 1000), privacy: .public)kbps observed=\(Int(event.observedBitrate / 1000), privacy: .public)kbps switches=\(event.numberOfMediaRequests, privacy: .public)")
        }

        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                switch item.status {
                case .unknown:
                    self.log.info("AVPlayerItem status: unknown")
                case .readyToPlay:
                    self.log.info("AVPlayerItem status: readyToPlay (duration=\(item.duration.seconds, privacy: .public)s)")
                case .failed:
                    let err = item.error as NSError?
                    self.log.error("AVPlayerItem status: FAILED domain=\(err?.domain ?? "?", privacy: .public) code=\(err?.code ?? 0, privacy: .public) info=\(String(describing: err?.userInfo), privacy: .public)")
                    // Ignore failures of an item that's no longer current (user moved on).
                    if item === self.streamedItem {
                        self.handleStreamFailure()
                    }
                @unknown default:
                    break
                }
            }
        }

        itemErrorLogObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let entry = item?.errorLog()?.events.last else { return }
            self?.log.error("AVPlayerItem error-log: domain=\(entry.errorDomain, privacy: .public) code=\(entry.errorStatusCode, privacy: .public) comment=\(entry.errorComment ?? "", privacy: .public) URI=\(entry.uri ?? "", privacy: .public)")
        }
    }

    /// Playback pipeline (CLAUDE.md §7):
    ///   1. **Local file** — an earlier download plays straight from disk (offline-capable).
    ///   2. **Stream** — `StreamResolver` finds a remote URL (visionos HLS in ~0.5 s, or yt-dlp's
    ///      360p mp4 for "made for kids" videos). No file is written unless the user enabled
    ///      "Save videos while playing", which downloads in the background meanwhile.
    ///   3. **Download first** — the old path (`DownloadManager.ensureDownloaded`), only when no
    ///      stream could be resolved or AVPlayer fails on the stream (`handleStreamFailure`).
    private func resolveAndPlay(video: Video, autoplay: Bool, skipRecommendations: Bool = false) async {
        log.info("resolveAndPlay: start for \(video.id, privacy: .public)")
        let quality = preferences.preferredQuality
        loadState = .resolving

        if let local = DownloadManager.shared.localFile(for: video.id) {
            log.info("resolveAndPlay: local file \(local.lastPathComponent, privacy: .public)")
            startPlayback(of: video, item: AVPlayerItem(url: local), streamed: false, autoplay: autoplay)
        } else {
            do {
                let stream = try await StreamResolver.shared.resolve(videoID: video.id, quality: quality)
                // The user may have tapped another video while we were resolving.
                guard currentVideo?.id == video.id else { return }
                startPlayback(of: video, item: makeStreamItem(stream, quality: quality), streamed: true, autoplay: autoplay)
                if preferences.saveWhilePlaying {
                    DownloadManager.shared.startDownload(video)
                }
            } catch {
                guard currentVideo?.id == video.id else { return }
                log.error("resolveAndPlay: no stream for \(video.id, privacy: .public) — downloading first")
                guard await playViaDownload(video: video, autoplay: autoplay) else { return }
            }
        }

        // Fire-and-forget queue fill — uses YouTube's `/next` (WEB) endpoint, independent of the
        // `/player` request above, so it can't interfere with playback that's already running.
        // Suppressed only for curated batch actions (playlist Play all / Shuffle all), whose
        // callers pre-populated the queue — that's also why prefetch must wait for the fill
        // otherwise: with just `[currentVideo]` queued, `upcomingItems(count: 1)` is empty.
        if !skipRecommendations {
            Task { [weak self] in
                await self?.fillQueueWithRecommendations(for: video)
                self?.prefetchNextUpcoming()
            }
        } else {
            prefetchNextUpcoming()
        }
    }

    /// Download-first fallback (tiers 1 + 2 of the old pipeline). Shows download progress in
    /// the mini player. Returns `false` (and sets `.failed`) when nothing could be fetched.
    private func playViaDownload(video: Video, autoplay: Bool, resumeAt: TimeInterval = 0) async -> Bool {
        startProgressObservation(for: video.id)
        defer { stopProgressObservation() }
        do {
            loadState = .resolving
            let fileURL = try await DownloadManager.shared.ensureDownloaded(
                video: video,
                quality: preferences.preferredQuality,
                priority: .userInitiated
            )
            guard currentVideo?.id == video.id else { return false }
            log.info("playViaDownload: local file \(fileURL.lastPathComponent, privacy: .public)")
            startPlayback(of: video, item: AVPlayerItem(url: fileURL), streamed: false, autoplay: autoplay)
            if resumeAt > 1 { seek(to: resumeAt) }
            return true
        } catch {
            guard currentVideo?.id == video.id else { return false }
            log.error("playViaDownload: FAILED for \(video.id, privacy: .public): \(String(describing: error), privacy: .public)")
            loadState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return false
        }
    }

    private func startPlayback(of video: Video, item: AVPlayerItem, streamed: Bool, autoplay: Bool) {
        streamedItem = streamed ? item : nil
        loadItem(item)
        loadState = .readyToPlay
        updateNowPlaying()
        if autoplay { play() }
        log.info("startPlayback: \(video.id, privacy: .public) streamed=\(streamed, privacy: .public)")
    }

    /// Builds the `AVPlayerItem` for a resolved stream. Headers go on the asset (all range
    /// requests of a progressive file carry them); HLS is capped to the preferred quality
    /// via `preferredMaximumResolution`, since we hand AVPlayer the whole adaptive ladder.
    ///
    /// The User-Agent goes through `AVURLAssetHTTPUserAgentKey`, not the header dictionary:
    /// on iOS a `User-Agent` inside `AVURLAssetHTTPHeaderFieldsKey` doesn't reach the CDN,
    /// requests go out as `AppleCoreMedia/…`, and YouTube 403s the yt-dlp URLs of "made for
    /// kids" videos — AVPlayer reported that as -11828 "format not supported".
    private func makeStreamItem(_ stream: ResolvedStream, quality: VideoQuality) -> AVPlayerItem {
        var headers = stream.httpHeaders
        var options: [String: Any] = [:]
        if let userAgent = headers.removeValue(forKey: "User-Agent") {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: stream.url, options: options))
        if stream.kind == .hls {
            let cap = CGFloat(StreamResolver.heightCap(for: quality))
            item.preferredMaximumResolution = CGSize(width: (cap * 16 / 9).rounded(), height: cap)
        }
        return item
    }

    /// Called when the current `AVPlayerItem` fails. For a stream (expired / 403'd URL, broken
    /// HLS), drop the cached URL and fall back to downloading the file once; a failing local
    /// file has nothing left to fall back to.
    private func handleStreamFailure() {
        guard let video = currentVideo, streamedItem != nil else { return }
        streamedItem = nil
        // A mid-playback failure (network drop, URL expired) resumes where it broke off.
        let resumeAt = elapsed
        log.error("stream failed for \(video.id, privacy: .public) at \(Int(resumeAt), privacy: .public)s — falling back to download")
        loadState = .resolving
        Task { [weak self] in
            await StreamResolver.shared.invalidate(videoID: video.id)
            _ = await self?.playViaDownload(video: video, autoplay: true, resumeAt: resumeAt)
        }
    }

    /// Prepares just the next queued video so Next / auto-advance starts instantly:
    /// - default: resolves its stream URL into `StreamURLCache` (memory only, no storage);
    /// - with "Save videos while playing": downloads its file in the background instead.
    ///
    /// Only one item — a download chain would hold the single `PythonRunner` interpreter and
    /// delay the user's own taps. User-gated by `UserPreferences.prefetchNextInQueue`.
    private func prefetchNextUpcoming() {
        guard preferences.prefetchNextInQueue else {
            log.debug("prefetch: disabled in settings, skipping")
            return
        }
        guard let next = queue.upcomingItems(count: 1).first,
              DownloadManager.shared.localFile(for: next.id) == nil else { return }
        if preferences.saveWhilePlaying {
            log.info("prefetch: downloading \(next.id, privacy: .public)")
            DownloadManager.shared.startDownload(next)
        } else {
            log.info("prefetch: resolving stream for \(next.id, privacy: .public)")
            let quality = preferences.preferredQuality
            Task {
                await StreamResolver.shared.prefetch(videoID: next.id, quality: quality)
            }
        }
    }

    /// Fetches `MoreVideoInfosResponse` for the current video and appends the recommended videos to
    /// the queue. This is what makes the player behave like the YouTube app: tap any video and a
    /// fresh "up next" queue is ready to advance when the current track ends.
    private func fillQueueWithRecommendations(for seed: Video) async {
        do {
            let info = try await VideoService().fetchMoreInfo(id: seed.id)
            // Only append recommendations that aren't already queued, preserving the user's own
            // ordering if they came from a "Play all" playlist load.
            let existingIDs = Set(queue.items.map(\.id))
            let toAppend = info.recommended.filter { !existingIDs.contains($0.id) }
            for rec in toAppend {
                queue.append(rec)
            }
            log.info("Queued \(toAppend.count, privacy: .public) recommendations for \(seed.id, privacy: .public)")
        } catch {
            log.notice("Recommendation fetch failed for \(seed.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func installObservers() {
        // Periodic time observation via Combine-friendly bridging.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let item = self.player.currentItem {
                    let total = item.duration.seconds
                    if total.isFinite { self.duration = total }
                }
                self.updateNowPlaying()
            }
        }

        // Auto-advance on item end.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.preferences.autoplayNext { self.playNext() }
            }
        }

        // Mirror AVPlayer's transport state into our `isPlaying` flag so the custom transport row
        // under the video title (and the popup-bar play/pause glyph) reflects taps on the native
        // AVPlayerViewController controls. Without this, hitting the native pause button on the
        // video surface left our SwiftUI button showing "Pause" forever.
        // Persist user-driven speed changes from AVPlayerViewController's built-in speed menu.
        // The menu writes to `defaultRate`; KVO catches the write and we save it to prefs so the
        // next app launch starts at the same speed.
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            guard let newValue = change.newValue else { return }
            let rate = Double(newValue)
            // Sanity: defaultRate of 0 would mean "paused on play()" which YouTube/AVPlayerViewController
            // never offers as a user option. Ignore any such bogus write.
            guard rate > 0 else { return }
            Task { @MainActor in
                if abs(rate - self.preferences.playbackRate) > 0.001 {
                    self.log.info("playbackRate changed → \(rate, privacy: .public) (persisting)")
                    self.preferences.playbackRate = rate
                }
            }
        }

        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] avPlayer, _ in
            guard let self else { return }
            let status = avPlayer.timeControlStatus
            Task { @MainActor in
                switch status {
                case .playing:
                    if !self.isPlaying {
                        self.log.info("KVO timeControlStatus → playing (sync isPlaying=true)")
                        self.isPlaying = true
                    }
                case .paused:
                    if self.isPlaying {
                        self.log.info("KVO timeControlStatus → paused (sync isPlaying=false)")
                        self.isPlaying = false
                    }
                case .waitingToPlayAtSpecifiedRate:
                    // Buffering / stalled. Treat as "playing" so the UI still shows pause icon,
                    // matching what the native AVPlayerViewController shows.
                    if !self.isPlaying {
                        self.isPlaying = true
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    private func updateNowPlaying() {
        guard let video = currentVideo else { return }
        NowPlayingCenter.update(
            title: video.title,
            artist: video.channelName,
            duration: duration,
            elapsed: elapsed,
            rate: isPlaying ? 1.0 : 0.0,
            artwork: currentArtwork
        )
    }

    /// Resolves an artwork image for the given video and stores it in `currentArtwork`. Tries three
    /// sources in order:
    ///  1. Kingfisher's in-memory cache for the video's `thumbnailURL` (synchronous → no flicker).
    ///  2. `DownloadsStore`'s xattr-stored compressed thumbnail (for videos played from the Downloads tab,
    ///     where the constructed `Video` has `thumbnailURL == nil`).
    ///  3. Async network/disk fetch through Kingfisher.
    /// Clears artwork immediately so the previous video's preview doesn't linger on the lock screen.
    private func refreshArtwork(for video: Video) {
        currentArtwork = nil

        if let url = video.thumbnailURL,
           let cached = ImageCache.default.retrieveImageInMemoryCache(forKey: url.cacheKey) {
            currentArtwork = cached
            updateNowPlaying()
            return
        }

        // Xattr fallback for downloaded-only videos. `DownloadsStore.thumbnail(forVideoID:)`
        // is synchronous (the entries snapshot lives in memory) so we can decode + assign
        // inline rather than through a Task / background actor.
        let videoID = video.id
        if let data = DownloadsStore.shared.thumbnail(forVideoID: videoID),
           let image = UIImage(data: data) {
            currentArtwork = image
            updateNowPlaying()
        }

        // Async network/disk fetch as last resort.
        guard let url = video.thumbnailURL else { return }
        KingfisherManager.shared.retrieveImage(with: url) { [weak self, videoID = video.id] result in
            guard case .success(let value) = result else { return }
            Task { @MainActor in
                guard let self else { return }
                // Drop the result if the user switched videos while the fetch was inflight.
                guard self.currentVideo?.id == videoID else { return }
                self.currentArtwork = value.image
                self.updateNowPlaying()
            }
        }
    }
}
