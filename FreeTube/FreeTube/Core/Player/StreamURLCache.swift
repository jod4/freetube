import Foundation
import OSLog

/// In-memory cache of resolved stream URLs (plus the headers they need). Per CLAUDE.md §2/§7:
/// signed URLs are sensitive and time-limited — they never touch disk. 30-minute TTL, well
/// inside the ~6 h validity YouTube signs them for.
///
/// `formatID` is free-form; `StreamResolver` keys by the requested `VideoQuality.rawValue`,
/// so a quality change in Settings resolves afresh.
actor StreamURLCache {
    static let shared = StreamURLCache()

    struct Key: Hashable {
        let videoID: String
        let formatID: String
    }

    private struct Entry {
        let stream: ResolvedStream
        let expiresAt: Date
    }

    private var entries: [Key: Entry] = [:]
    private let ttl: TimeInterval
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "StreamURLCache")

    init(ttl: TimeInterval = 30 * 60) {
        self.ttl = ttl
    }

    func get(videoID: String, formatID: String) -> ResolvedStream? {
        let key = Key(videoID: videoID, formatID: formatID)
        guard let entry = entries[key] else { return nil }
        if entry.expiresAt < .now {
            entries[key] = nil
            return nil
        }
        return entry.stream
    }

    func set(videoID: String, formatID: String, stream: ResolvedStream) {
        let key = Key(videoID: videoID, formatID: formatID)
        entries[key] = Entry(stream: stream, expiresAt: .now.addingTimeInterval(ttl))
        log.debug("Cached stream for \(videoID, privacy: .public)/\(formatID, privacy: .public)")
    }

    /// Drops every cached stream of one video — called when AVPlayer fails on a cached URL so
    /// the next attempt doesn't hand it the same dead URL again.
    func remove(videoID: String) {
        entries = entries.filter { $0.key.videoID != videoID }
    }

    func purge() {
        entries.removeAll()
    }
}
