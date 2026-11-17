import SwiftUI
import SwiftData

/// Library → History → See all. Every video played on this device (`WatchHistoryEntry`),
/// newest first — no YouTube account involved. Swipe to remove one; the toolbar clears all.
/// Recording can be paused in Settings → History.
@available(iOS 17.0, *)
struct LocalHistoryScreen: View {
    @Query(sort: \WatchHistoryEntry.watchedAt, order: .reverse) private var entries: [WatchHistoryEntry]
    @Environment(PlayerStateManager.self) private var player
    @State private var showingClearConfirmation = false

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    systemImage: "clock",
                    title: "No history",
                    message: "Videos you watch appear here. History is stored on this device only."
                )
            } else {
                List {
                    ForEach(entries) { entry in
                        let video = entry.asVideo
                        VideoRow(video: video, onTap: { player.load(video) }, showsMoreMenu: true)
                            .swipeActions {
                                Button(role: .destructive) {
                                    let id = entry.videoID
                                    Task { await PersistenceWriter.shared.removeWatchHistory(videoID: id) }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("History")
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) {
                        showingClearConfirmation = true
                    }
                }
            }
        }
        .confirmationDialog("Clear the entire history?", isPresented: $showingClearConfirmation, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) {
                Task { await PersistenceWriter.shared.clearWatchHistory() }
            }
        }
    }
}
