import Foundation

/// Video IDs whose download the user cancelled (the ✕ in the Downloads transfer queue).
///
/// **Why a lock-protected registry instead of `Task.cancel()`:** the bytes are fetched by
/// yt-dlp inside the embedded Python interpreter, which Swift task cancellation can't reach.
/// yt-dlp itself checks for cancellation through its progress hook — `freetube_yt_dlp`
/// raises `yt_dlp.utils.DownloadCancelled` from the hook when `isCancelled(videoID:)` turns
/// true. That hook runs on the Python thread, so this type must be readable from any thread
/// (hence `nonisolated` + `NSLock`, not an actor or `@MainActor` state).
nonisolated final class DownloadCancellation: @unchecked Sendable {
    static let shared = DownloadCancellation()

    private let lock = NSLock()
    private var cancelled: Set<String> = []

    func cancel(videoID: String) {
        lock.lock()
        defer { lock.unlock() }
        cancelled.insert(videoID)
    }

    func isCancelled(videoID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(videoID)
    }

    /// Called when the cancelled download has fully wound down, so a later download of the
    /// same video starts clean.
    func clear(videoID: String) {
        lock.lock()
        defer { lock.unlock() }
        cancelled.remove(videoID)
    }
}
