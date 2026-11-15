import SwiftUI

/// **Trending** tab — the video feed that used to sit below the search field.
///
/// Signed in, it's the personalized `HomeScreenResponse` feed; anonymous, `HomeService`
/// falls back to the curated discovery grid (Trending / Music / Gaming / News / Sports).
/// The tab is hidden by default and only shown when `UserPreferences.showTrendingTabKey`
/// is switched on in Settings, so a hidden tab never fetches anything.
@available(iOS 17.0, *)
struct TrendingScreen: View {
    @State private var model = TrendingViewModel()
    @Environment(PlayerStateManager.self) private var player

    var body: some View {
        NavigationStack {
            feed
                .navigationTitle("Trending")
                .refreshable {
                    await model.refresh()
                }
                .task {
                    if model.sections.isEmpty { await model.load() }
                }
                // Reload whenever the auth status flips. After sign-in the YouTubeModel has
                // cookies attached, so `HomeScreenResponse` returns the personalized feed
                // instead of the anonymous discovery grid.
                .onChange(of: AuthState.shared.status, initial: false) { _, _ in
                    Task { await model.refresh() }
                }
                .errorToast($model.errorState)
        }
    }

    @ViewBuilder
    private var feed: some View {
        List {
            if model.sections.isEmpty && !model.isLoading {
                EmptyStateView(
                    systemImage: "play.rectangle.on.rectangle",
                    title: "Nothing here yet",
                    message: "Pull to refresh or sign in to see your home feed."
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            ForEach(model.sections) { section in
                if let title = section.title {
                    SectionHeader(verbatim: title)
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                ForEach(section.videos) { video in
                    VideoCard(video: video, onTap: { player.load(video) }, showsMoreMenu: true)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .onAppear {
                            guard section.id == model.sections.last?.id else { return }
                            guard section.videos.suffix(5).contains(where: { $0.id == video.id }) else { return }
                            guard model.continuationToken != nil, !model.isLoading else { return }
                            Task { await model.loadMore() }
                        }
                }
            }

            if model.isLoading {
                LoadingView()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
    }
}
