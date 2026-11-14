import CryptoKit
import Foundation
import OSLog

import YoutubeDL

/// Installs a **pinned, checksum-verified** yt-dlp release as the Python module YoutubeDL-iOS
/// loads (`YoutubeDL.pythonModuleURL`).
///
/// **Why pinned.** The embedded interpreter (kewlbear/Python-iOS) is **CPython 3.10**.
/// yt-dlp 2026.10.26 raised its minimum to Python 3.11 — its `__init__.py` raises
/// `ImportError("You are using an unsupported version of Python…")` on import. YoutubeDL-iOS
/// always fetches `releases/latest`, so every install from that day on got a yt-dlp that can't
/// even be imported and tier 1 of the playback pipeline (CLAUDE.md §7) failed for every video.
/// 2026.10.21 is the last release that accepts 3.10, and it vendors yt-dlp-ejs 0.8.0 — the
/// same version as our bundled `core.min.js` / `lib.min.js` (§15.11).
///
/// **Bumping the pin** requires all three: the release still supports Python 3.10 (check the
/// `sys.version_info` guard at the top of `yt_dlp/__init__.py` for that tag), its
/// `yt_dlp/extractor/youtube/jsc/_builtin/vendor/_info.py` `VERSION` matches
/// `EJSResources.version`, and `sha256` is taken from that release's `SHA2-256SUMS`.
///
/// **Why our own download instead of `YoutubeDL.downloadPythonModule(from:)`.** The package
/// moves the downloaded file into place unverified. We verify the SHA-256 first and only then
/// swap it in, so a truncated download or a tampered file never becomes executable code.
actor YtDlpInstaller {
    static let shared = YtDlpInstaller()

    static let version = "2026.10.21"
    private static let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.21/yt-dlp")
    private static let sha256 = "b7af77f686e95f7845ce8d09d21957718febb8b48b30555adb9dd2292ad7bf14"

    enum InstallError: LocalizedError {
        case invalidURL
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid yt-dlp download URL"
            case .checksumMismatch: return String(localized: "The downloaded yt-dlp file failed its integrity check.")
            }
        }
    }

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "YtDlpInstaller")
    /// Set once the on-disk module is known to be the pinned build, so the hash isn't
    /// recomputed on every play tap. Process-lifetime only.
    private var verified = false
    /// Coalesces concurrent callers (launch-time updater + an early play tap) onto one download.
    private var inFlight: Task<Void, Error>?

    /// Ensures the pinned yt-dlp is on disk. Cheap after the first successful call. With
    /// `force`, re-verifies the file even if it was already checked this launch.
    func ensureInstalled(force: Bool = false) async throws {
        if verified && !force { return }
        if let inFlight { return try await inFlight.value }

        let task = Task.detached(priority: .utility) { [log] in
            let target = YoutubeDL.pythonModuleURL
            if Self.fileMatchesPin(target) {
                log.info("[ytdlp-install] pinned \(Self.version, privacy: .public) already installed")
                return
            }
            guard let url = Self.downloadURL else { throw InstallError.invalidURL }
            log.notice("[ytdlp-install] installing pinned yt-dlp \(Self.version, privacy: .public)")
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            guard Self.fileMatchesPin(tempURL) else {
                log.error("[ytdlp-install] checksum mismatch — keeping existing module")
                throw InstallError.checksumMismatch
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: target)
            }
            log.notice("[ytdlp-install] pinned yt-dlp \(Self.version, privacy: .public) installed")
        }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
        verified = true
    }

    private nonisolated static func fileMatchesPin(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == sha256
    }
}
