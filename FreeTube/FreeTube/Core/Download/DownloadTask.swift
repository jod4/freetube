import Foundation

/// Where a download falls in the manager's queue.
///
/// `.userInitiated` is for the case where the user is **actively waiting** — e.g. they just
/// tapped a video in search results expecting playback to start. Such requests jump ahead of
/// any pending `.background` items (playlist Download All, queue prefetch) inside
/// `PythonRunner`. The currently-running yt-dlp can't be preempted (Python doesn't have a safe
/// interrupt point), but the high-priority item runs immediately after it.
///
/// `.background` is the default for batch downloads and prefetch.
enum DownloadPriority: Sendable {
    case userInitiated
    case background
}

/// Public-facing snapshot of a download. The download manager surfaces these to UI via `AsyncStream`.
struct DownloadTaskSnapshot: Identifiable, Sendable {
    enum State: Sendable, Equatable {
        case queued
        case downloading(progress: Double)
        /// Bytes are in; joining video + audio (ffmpeg) and writing metadata. Can take a while
        /// for long videos on older devices — shown as an indeterminate bar, not a stuck 100 %.
        case processing
        case paused
        case completed(URL)
        case failed(String)
    }

    let id: String
    let videoID: String
    let title: String
    let state: State
    let createdAt: Date
    /// Which stream is transferring while `.downloading`: "video" / "audio" (yt-dlp downloads
    /// the two legs one after the other, each 0 → 100 %), nil when unknown.
    var phase: String? = nil
}
