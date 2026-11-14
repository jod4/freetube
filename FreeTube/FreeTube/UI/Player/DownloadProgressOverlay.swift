import SwiftUI

/// Black-translucent overlay rendered on top of the player surface while a video is being fetched
/// by yt-dlp. Reads `PlayerStateManager.loadState` and only draws itself during `.resolving` and
/// `.downloading` — once `.readyToPlay` flips on, it disappears.
@available(iOS 17.0, *)
struct DownloadProgressOverlay: View {
    let state: PlayerStateManager.LoadState

    var body: some View {
        switch state {
        case .resolving:
            overlay(label: Text("Preparing…"), progress: nil)
        case .downloading(let progress, let phase):
            overlay(label: label(for: progress, phase: phase), progress: progress)
        case .failed(let message):
            overlay(label: Text(verbatim: message), progress: nil, error: true)
        case .idle, .readyToPlay:
            EmptyView()
        }
    }

    @ViewBuilder
    private func overlay(label: Text, progress: Double?, error: Bool = false) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                if error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.3)
                }
                label
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if let progress {
                    ProgressView(value: progress)
                        .tint(.white)
                        .frame(maxWidth: 220)
                        .padding(.horizontal, 24)
                }
            }
        }
        .transition(.opacity)
    }

    /// Phrasing rules:
    /// - "Downloading video 42%" / "Downloading audio 75%" when we know which stream is in flight
    /// - "Processing video…" between phases (yt-dlp switching from video → audio, or post-download mux)
    /// - "Downloading…" as a generic fallback
    private func label(for progress: Double?, phase: String?) -> Text {
        guard let progress else { return Text("Processing video…") }
        let percent = Int(progress * 100)
        switch phase {
        case "video": return Text("Downloading video \(percent)%")
        case "audio": return Text("Downloading audio \(percent)%")
        default: return Text("Downloading \(percent)%")
        }
    }
}
