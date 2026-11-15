import SwiftUI
import SwiftData

/// **Search** tab. Title "Search", a full-width search field directly below it, and the
/// results below that. While nothing has been searched yet, `SearchContent` shows the
/// recent queries (or a short hint when there are none). The video feed that used to sit
/// here lives in the separate Trending tab (`TrendingScreen`).
///
/// **Search field placement:** `.navigationBarDrawer(displayMode: .always)` pins the field
/// under the large title at full width. The default placement puts it as a small field in
/// the trailing corner of the navigation bar on iPadOS 18+, next to the top tab bar.
///
/// **Mac runtime** gets a custom inline field via `MacInlineSearchField`, because
/// `.searchable` collapses to a trailing toolbar button on Designed-for-iPad-on-Mac and
/// real Catalyst, which is awkward at desktop widths.
@available(iOS 17.0, *)
struct SearchScreen: View {
    @State private var searchModel = SearchViewModel()
    @Environment(\.modelContext) private var modelContext

    /// Recent search queries. Read here so `runSearch` can upsert by query string.
    @Query(sort: \SearchHistoryEntry.searchedAt, order: .reverse) private var history: [SearchHistoryEntry]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if MacIntegration.isRunningOnMac {
                    MacInlineSearchField(query: $searchModel.query) {
                        Task { await runSearch() }
                    }
                }

                SearchContent(model: searchModel) {
                    Task { await runSearch() }
                }
            }
            .navigationTitle("Search")
            .modifier(ConditionalSearchable(
                text: $searchModel.query,
                enabled: !MacIntegration.isRunningOnMac,
                prompt: "Search YouTube"
            ))
            .onSubmit(of: .search) {
                Task { await runSearch() }
            }
            // When the user clears the field, drop the previous results + suggestions so the
            // recent-searches list re-renders cleanly.
            .onChange(of: searchModel.query) { _, newValue in
                if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchModel.clearResults()
                }
            }
            .refreshable {
                if searchModel.results != nil {
                    await searchModel.submit()
                }
            }
        }
    }

    /// Persists the trimmed query to history (upsert by query string), then fires
    /// `searchModel.submit()`.
    private func runSearch() async {
        let trimmed = searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let existing = history.first(where: { $0.query == trimmed }) {
            existing.searchedAt = .now
        } else {
            modelContext.insert(SearchHistoryEntry(query: trimmed))
        }
        try? modelContext.save()
        await searchModel.submit()
    }
}

// MARK: - Content

/// Renders the body of the search experience — results / suggestions / history / empty
/// state — without owning its own navigation stack or search bar. Hosted by `SearchScreen`,
/// which provides the `.searchable` text input and the `onRunSearch` callback so the
/// history upsert + submit stay in one place at the host level.
@available(iOS 17.0, *)
struct SearchContent: View {
    @Bindable var model: SearchViewModel
    let onRunSearch: () -> Void
    @Environment(PlayerStateManager.self) private var player
    /// 1–3, from `VideoGridColumns` breakpoints.
    @State private var columns = 1
    @Environment(\.modelContext) private var modelContext

    /// Recently entered search queries, newest first. Tapping one re-runs the search.
    @Query(sort: \SearchHistoryEntry.searchedAt, order: .reverse) private var history: [SearchHistoryEntry]

    var body: some View {
        Group {
            if let results = model.results {
                resultsList(results)
            } else if !model.suggestions.isEmpty {
                ScrollView {
                    SearchSuggestionList(suggestions: model.suggestions) { suggestion in
                        model.query = suggestion.text
                        onRunSearch()
                    }
                }
            } else if model.isLoading {
                LoadingView()
            } else if !history.isEmpty {
                historyList
            } else {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: "Search YouTube",
                    message: "Find videos, channels, and playlists."
                )
            }
        }
        .errorToast($model.errorState)
    }

    @ViewBuilder
    private var historyList: some View {
        List {
            Section("Recent searches") {
                ForEach(history) { entry in
                    Button {
                        model.query = entry.query
                        onRunSearch()
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(entry.query)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        modelContext.delete(history[index])
                    }
                    try? modelContext.save()
                }

                if !history.isEmpty {
                    Button("Clear all", role: .destructive) {
                        for entry in history { modelContext.delete(entry) }
                        try? modelContext.save()
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// Results as one scroll view: channels and playlists (rows, side by side when there's
    /// room), then the videos as a responsive `VideoGrid` — compact rows on narrow screens,
    /// 2–3 columns of cards on iPad.
    @ViewBuilder
    private func resultsList(_ results: SearchResult) -> some View {
        ScrollView {
            // Plain VStack: `VideoGrid` must be the only lazy container (see its doc comment).
            VStack(alignment: .leading, spacing: 12) {
                if !results.channels.isEmpty {
                    SectionHeader(title: "Channels")
                    rowGrid {
                        ForEach(results.channels) { channel in
                            NavigationLink {
                                ChannelScreen(channelID: channel.id)
                            } label: {
                                ChannelRow(channel: channel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !results.playlists.isEmpty {
                    SectionHeader(title: "Playlists")
                    rowGrid {
                        ForEach(results.playlists) { playlist in
                            NavigationLink {
                                PlaylistScreen(playlistID: playlist.id)
                            } label: {
                                PlaylistRow(playlist: playlist, showsMoreMenu: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !results.videos.isEmpty {
                    SectionHeader(title: "Videos")
                    VideoGrid(
                        videos: results.videos,
                        columns: columns,
                        compactWhenSingleColumn: true,
                        showsMoreMenu: true,
                        onTap: { player.load($0) },
                        onItemAppear: { index in
                            guard index >= results.videos.count - 5,
                                  results.continuationToken != nil,
                                  !model.isLoading else { return }
                            Task { await model.loadMore() }
                        }
                    )
                    if model.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .readVideoGridColumns(into: $columns)
    }

    /// Channel / playlist rows in the same column count as the video grid. A sibling of the
    /// `VideoGrid`, not a wrapper around it, so it doesn't nest lazy containers.
    private func rowGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: columns),
            spacing: 12,
            content: content
        )
        .padding(.horizontal)
    }
}

// MARK: - Search field helpers

/// Inline search field used on Mac (Designed-for-iPad-on-Mac or real Catalyst). `.searchable`
/// collapses to a trailing toolbar button on Mac runtimes — awkward at desktop widths. The
/// host view embeds this above its content and skips `.searchable` via `ConditionalSearchable`.
@available(iOS 17.0, *)
struct MacInlineSearchField: View {
    @Binding var query: String
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .onSubmit(onSubmit)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Applies `.searchable` only when `enabled`. We can't put `.searchable` behind a plain
/// `if` because it returns an opaque `some View` whose type differs between branches,
/// which breaks SwiftUI identity. A `ViewModifier` keeps the outer type stable across the
/// runtime toggle (Mac → inline field, iOS → native searchable).
@available(iOS 17.0, *)
struct ConditionalSearchable: ViewModifier {
    @Binding var text: String
    let enabled: Bool
    var prompt: LocalizedStringKey = "Search"

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(prompt)
            )
        } else {
            content
        }
    }
}
