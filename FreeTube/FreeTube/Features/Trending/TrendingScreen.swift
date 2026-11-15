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
    /// 1–3, from `VideoGridColumns` breakpoints.
    @State private var columns = 1
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
        ScrollView {
            // Plain VStack on purpose: `VideoGrid` must be the only lazy container (see its
            // doc comment), so all feed sections go into that one grid.
            VStack(alignment: .leading, spacing: 12) {
                if model.sections.isEmpty && !model.isLoading {
                    EmptyStateView(
                        systemImage: "play.rectangle.on.rectangle",
                        title: "Nothing here yet",
                        message: "Pull to refresh or sign in to see your home feed."
                    )
                }

                let sections = model.sections.map {
                    VideoGridSection(id: $0.id, title: $0.title, videos: $0.videos)
                }
                let total = VideoGrid.totalCount(of: sections)
                VideoGrid(
                    sections: sections,
                    columns: columns,
                    showsMoreMenu: true,
                    onTap: { player.load($0) },
                    onItemAppear: { index in
                        guard index >= total - 5 else { return }
                        guard model.continuationToken != nil, !model.isLoading else { return }
                        Task { await model.loadMore() }
                    }
                )

                if model.isLoading {
                    LoadingView()
                }
            }
            .padding(.vertical, 8)
        }
        .readVideoGridColumns(into: $columns)
    }
}
