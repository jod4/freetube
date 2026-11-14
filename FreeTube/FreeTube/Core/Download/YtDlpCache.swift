import Foundation
import OSLog

/// yt-dlp's on-disk cache directory, plus pruning for the preprocessed-player entries that
/// `PythonJSBridge` enables.
///
/// **Why.** Solving YouTube's n/sig challenges first *preprocesses* the ~3 MB player.js
/// (meriyah parse → AST transform → astring generate). On an iPad 7 that is ~5.5 s per video,
/// every video. yt-dlp can cache the preprocessed player per player URL, after which a solve is
/// a plain evaluation (~20× faster: 2.25 s → 0.11 s measured on macOS JSC). Upstream ships that
/// cache disabled (`_ENABLE_PREPROCESSED_PLAYER_CACHE = False`, "files are large and we do not
/// support rotation") — we turn it on and do the rotation here.
///
/// **Location.** `Library/Caches/yt-dlp` — purgeable by iOS under storage pressure, never backed
/// up, so a lost cache only costs one slow solve. Entries contain YouTube's public player script
/// only — no cookies, no signed URLs.
nonisolated enum YtDlpCache {
    /// Preprocessed players kept on disk (~4 MB each). YouTube rotates the player every few days
    /// to weeks and can A/B two versions at once; three covers that without unbounded growth.
    static let keptPlayerCount = 3

    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "YtDlpCache")

    /// Directory passed to yt-dlp as `cachedir`. Created on first access.
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("yt-dlp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deletes all but the `keptPlayerCount` most recently written preprocessed players.
    /// yt-dlp names them `challenge-solver/player,3A<url-encoded player URL>.json`
    /// (`Cache._get_cache_fn`: `quote(key)` with `%` → `,`). Cheap — one directory listing.
    static func prunePreprocessedPlayers() {
        let section = directory.appendingPathComponent("challenge-solver", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: section,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let players = files
            .filter { $0.lastPathComponent.hasPrefix("player,3A") }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }

        for (url, _) in players.dropFirst(keptPlayerCount) {
            try? fm.removeItem(at: url)
            log.info("[ytdlp-cache] pruned old preprocessed player \(url.lastPathComponent, privacy: .public)")
        }
    }
}
