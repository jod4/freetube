import Foundation
import OSLog

/// A remote URL `AVPlayer` can stream directly, plus the HTTP headers its requests need.
struct ResolvedStream: Sendable {
    enum Kind: String, Sendable {
        /// HLS master playlist — adaptive; the player caps it via `preferredMaximumResolution`.
        case hls
        /// Single progressive mp4 with audio + video (typically itag 18, 360p).
        case progressive
    }

    let url: URL
    /// Sent with every request of the asset (`AVURLAssetHTTPHeaderFieldsKey`). For a
    /// progressive file that covers all range requests; for HLS only the master playlist.
    let httpHeaders: [String: String]
    let kind: Kind
    /// Which tier produced it, for logs ("visionos", "yt-dlp", "ios").
    let source: String
}

/// Finds a stream for instant playback — the first stage of the playback pipeline
/// (CLAUDE.md §7). Tiers, first hit wins:
///
/// 1. **`VISIONOS` client HLS** (`VideoService.fetchInfoViaVisionOS`) — pure Swift, ~0.5 s,
///    adaptive up to 1080p, no PoT / n-cipher. Covers normal videos.
/// 2. **yt-dlp extraction only** (`YtDlpInfoService.probe`, no download) — for "made for
///    kids" videos, which `VISIONOS` answers with `UNPLAYABLE`. yt-dlp falls back to other
///    clients (`tv_simply`, `web_embedded` + JS challenge solving) and we stream the best
///    progressive mp4 within the quality cap (360p in practice) **with yt-dlp's
///    `http_headers`** — those URLs 403 under AVPlayer's default User-Agent. Several seconds
///    on an iPad 7 and serialized behind any running yt-dlp download (`PythonRunner`).
/// 3. **iOS client** (`VideoService.fetchInfo`) — HLS or progressive. The former tier-3
///    streaming fallback, kept last: it is the only tier that may touch the signed-in
///    session (`clearSessionIfLoginRequired`).
///
/// Results are cached in `StreamURLCache` (memory only, 30 min), so a prefetched next video
/// starts without any network round trip.
@available(iOS 17.0, *)
final class StreamResolver: Sendable {
    static let shared = StreamResolver()

    private let videoService = VideoService()
    private let infoService = YtDlpInfoService()
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "StreamResolver")

    /// - Parameter allowYtDlp: `false` for prefetching — tier 2 occupies the single Python
    ///   interpreter for seconds and would delay the user's next tap.
    func resolve(videoID: String, quality: VideoQuality, allowYtDlp: Bool = true) async throws -> ResolvedStream {
        let cacheKey = quality.rawValue
        if let cached = await StreamURLCache.shared.get(videoID: videoID, formatID: cacheKey) {
            log.info("resolve(\(videoID, privacy: .public)): cache hit (\(cached.source, privacy: .public))")
            return cached
        }
        let startedAt = Date()
        let cap = Self.heightCap(for: quality)

        var stream: ResolvedStream?
        if let info = try? await videoService.fetchInfoViaVisionOS(id: videoID), let hls = info.streamingURL {
            stream = ResolvedStream(url: hls, httpHeaders: [:], kind: .hls, source: "visionos")
        }
        if stream == nil, allowYtDlp {
            stream = await resolveViaYtDlp(videoID: videoID, maxHeight: cap)
        }
        if stream == nil, let info = try? await videoService.fetchInfo(id: videoID) {
            if let hls = info.streamingURL {
                stream = ResolvedStream(url: hls, httpHeaders: [:], kind: .hls, source: "ios")
            } else if let url = Self.bestProgressiveURL(in: info.formats, maxHeight: cap) {
                stream = ResolvedStream(url: url, httpHeaders: [:], kind: .progressive, source: "ios")
            }
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
        guard let stream else {
            log.error("resolve(\(videoID, privacy: .public)): no stream after \(elapsed, privacy: .public)s")
            throw YouTubeServiceError.streamExtractionFailed
        }
        log.info("resolve(\(videoID, privacy: .public)): \(stream.kind.rawValue, privacy: .public) via \(stream.source, privacy: .public) in \(elapsed, privacy: .public)s")
        await StreamURLCache.shared.set(videoID: videoID, formatID: cacheKey, stream: stream)
        return stream
    }

    /// Resolves the next queue item ahead of time so tapping Next starts instantly. Swift
    /// tiers only (see `allowYtDlp`); failures are silent — the real tap resolves again.
    func prefetch(videoID: String, quality: VideoQuality) async {
        _ = try? await resolve(videoID: videoID, quality: quality, allowYtDlp: false)
    }

    /// Drops cached streams for a video after AVPlayer failed on one.
    func invalidate(videoID: String) async {
        await StreamURLCache.shared.remove(videoID: videoID)
    }

    // MARK: - Tiers

    /// Picks a muxed (audio + video) format from yt-dlp's extraction and returns the first
    /// that passes `preflight`. Order: **HLS** within the cap, highest first (on the iPad the
    /// `web_embedded` HLS variants of kids videos stream fine up to 1080p, while the
    /// progressive itag 18 answered 403 — 2026-11-16), then progressive mp4s.
    private func resolveViaYtDlp(videoID: String, maxHeight: Int) async -> ResolvedStream? {
        do {
            let media = try await infoService.probe(url: "https://www.youtube.com/watch?v=\(videoID)")
            let muxed: [RemoteFormat] = media.formats.filter { format in
                format.isProgressive && format.url != nil && (format.height ?? 0) <= maxHeight
            }
            let hls = muxed
                .filter { $0.protocolKind == RemoteFormat.ProtocolKind.hls }
                .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
            let progressive = muxed
                .filter { $0.protocolKind == RemoteFormat.ProtocolKind.https && $0.ext == "mp4" }
                .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
            // Best HLS + best progressive is enough: variants of one kind share their fate.
            let candidates: [(RemoteFormat, ResolvedStream.Kind)] =
                hls.prefix(1).map { ($0, .hls) } + progressive.prefix(1).map { ($0, .progressive) }
            for (format, kind) in candidates {
                guard let url = format.url else { continue }
                log.info("yt-dlp tier: \(kind.rawValue, privacy: .public) itag \(format.id, privacy: .public) \(format.height ?? 0, privacy: .public)p host=\(url.host() ?? "?", privacy: .public)")
                let usable = kind == .hls
                    ? await preflightHLS(url, headers: format.httpHeaders)
                    : await preflight(url, headers: format.httpHeaders)
                if usable {
                    return ResolvedStream(url: url, httpHeaders: format.httpHeaders, kind: kind, source: "yt-dlp")
                }
            }
            log.notice("yt-dlp tier: no usable muxed format ≤ \(maxHeight, privacy: .public)p for \(videoID, privacy: .public)")
            return nil
        } catch {
            log.notice("yt-dlp tier failed for \(videoID, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Helpers

    /// HLS variant check: the playlist must load, and its first media segment must answer
    /// 2xx — with the same User-Agent AVPlayer will send (`AVURLAssetHTTPUserAgentKey`
    /// applies to every request of the asset, segments included).
    private func preflightHLS(_ url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 10)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let playlist = String(data: data, encoding: .utf8), playlist.hasPrefix("#EXTM3U") else {
            log.notice("preflightHLS: playlist unavailable")
            return false
        }
        // A master playlist only lists variants; good enough. A media playlist: test a segment.
        guard !playlist.contains("#EXT-X-STREAM-INF"),
              let line = playlist.split(whereSeparator: \.isNewline).first(where: { !$0.hasPrefix("#") && !$0.isEmpty }),
              let segment = URL(string: String(line), relativeTo: url)?.absoluteURL else {
            return true
        }
        var segmentRequest = URLRequest(url: segment, timeoutInterval: 10)
        if let userAgent = headers["User-Agent"] { segmentRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        segmentRequest.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        let status = ((try? await URLSession.shared.data(for: segmentRequest))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        log.info("preflightHLS: segment HTTP \(status, privacy: .public)")
        return (200...299).contains(status)
    }

    /// Fetches the first two bytes the way AVPlayer will (same headers). A dead URL (403 from
    /// a missing PoT / UA binding) then falls through to the next tier instead of failing
    /// inside AVPlayer with an opaque "format not supported". ~0.1–0.3 s.
    private func preflight(_ url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 10)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            log.notice("preflight: no response")
            return false
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
        let ok = (200...299).contains(http.statusCode) && (type.hasPrefix("video/") || type.hasPrefix("audio/"))
        log.info("preflight: HTTP \(http.statusCode, privacy: .public) \(type, privacy: .public) → \(ok ? "ok" : "skip", privacy: .public)")
        return ok
    }

    /// `.auto` → 1080, `.audioOnly` (cap 0) → treated as uncapped, since we always need a
    /// video track for AVPlayer's surface.
    static func heightCap(for quality: VideoQuality) -> Int {
        guard let cap = quality.heightCap, cap > 0 else { return 1080 }
        return cap
    }

    private static func bestProgressiveURL(in formats: [VideoFormat], maxHeight: Int) -> URL? {
        formats
            .filter { $0.containsBothTracks && $0.url != nil }
            .filter { ($0.height ?? .max) <= maxHeight }
            .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
            .first?
            .url
    }
}
