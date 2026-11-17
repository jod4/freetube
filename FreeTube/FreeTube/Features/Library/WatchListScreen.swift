import SwiftUI
import SwiftData

/// Library → Watch list → See all. The local "watch later" list (`FavoriteVideo` rows),
/// newest first. Swipe to remove; streaming happens on play, nothing is stored but the entry.
@available(iOS 17.0, *)
struct WatchListScreen: View {
    @Query(sort: \FavoriteVideo.savedAt, order: .reverse) private var entries: [FavoriteVideo]
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerStateManager.self) private var player

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    systemImage: "bookmark",
                    title: "Watch list is empty",
                    message: "Use “Add to watch list” in a video's … menu to save it for later."
                )
            } else {
                List {
                    ForEach(entries) { entry in
                        let video = entry.asVideo
                        VideoRow(video: video, onTap: { player.load(video) }, showsMoreMenu: true)
                            .swipeActions {
                                Button(role: .destructive) {
                                    modelContext.delete(entry)
                                    try? modelContext.save()
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Watch list")
    }
}
