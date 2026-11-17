import SwiftUI

/// The YouTube-account part of the Library tab: watch history, playlists, own channel,
/// liked videos and Watch later, all fetched from the signed-in account.
///
/// Only mounted when Settings → YouTube account → "Use YouTube account" is on **and** the
/// user is signed in (CLAUDE.md §9). The app's default is account-free: the local watch list
/// and history above it in `LibraryScreen` cover the same ground without YouTube.
@available(iOS 17.0, *)
struct YouTubeLibrarySection: View {
    @State private var libraryModel = LibraryViewModel()

    var body: some View {
        menuSection
            .task { await libraryModel.load() }
    }

    /// Five destinations as a single section (Movies removed — YouTubeKit doesn't expose it).
    /// Each row renders a custom `HStack { icon, VStack(title, subtitle) }` so we can show a
    /// count under the title. Subtitles are best-effort: when the library response hasn't
    /// loaded yet they read "—" and update reactively once `libraryModel.library` populates.
    @ViewBuilder
    private var menuSection: some View {
        Section {
            menuRow(
                title: "Watch history",
                subtitle: countSubtitle(libraryModel.library?.historyCount) { Text("\($0) videos") },
                systemImage: "clock.fill"
            ) {
                HistoryScreen()
            }

            menuRow(
                title: "Playlists",
                subtitle: countSubtitle(libraryModel.library?.playlists.count) { Text("\($0) playlists") },
                systemImage: "rectangle.stack.fill"
            ) {
                UserPlaylistsScreen(playlists: libraryModel.library?.playlists ?? [])
            }

            menuRow(
                title: "Your videos",
                subtitle: Text("Your YouTube channel"),
                systemImage: "person.crop.rectangle.fill"
            ) {
                if let channelID = libraryModel.library?.userChannelID {
                    ChannelScreen(channelID: channelID)
                } else {
                    EmptyStateView(
                        systemImage: "person.crop.rectangle.fill",
                        title: "No channel detected",
                        message: "Your YouTube channel ID wasn't returned in the library response. Try refreshing the Library screen."
                    )
                }
            }

            // VLLL — YouTube's well-known playlist ID for the signed-in user's Liked Videos.
            menuRow(
                title: "Liked videos",
                subtitle: countSubtitle(libraryModel.library?.likedCount) { Text("\($0) videos") },
                systemImage: "hand.thumbsup.fill"
            ) {
                PlaylistScreen(playlistID: "VLLL")
            }

            // VLWL — Watch Later.
            menuRow(
                title: "Watch later",
                subtitle: countSubtitle(libraryModel.library?.watchLaterCount) { Text("\($0) videos") },
                systemImage: "clock.arrow.circlepath"
            ) {
                PlaylistScreen(playlistID: "VLWL")
            }
        } header: {
            Text(verbatim: "YouTube")
        }
    }

    /// Custom row builder so we can put the count under the title (the system's `Label` only
    /// shows a single line of text next to its icon). Pushes the given destination in the
    /// surrounding NavigationStack.
    @ViewBuilder
    private func menuRow<Destination: View>(
        title: LocalizedStringKey,
        subtitle: Text,
        systemImage: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Builds the "N videos" / "N playlists" subtitle. When the library response hasn't
    /// returned yet (count is nil), we render "—" rather than a hardcoded "0" so the user can
    /// tell "still loading" from "actually empty".
    /// `format` builds the localized, pluralized line (e.g. `Text("\($0) videos")`, which the
    /// catalog resolves via its plural variations).
    private func countSubtitle(_ count: Int?, format: (Int) -> Text) -> Text {
        guard let count else { return Text(verbatim: "—") }
        return format(count)
    }
}

// MARK: - User playlists list

/// Simple list of user-owned playlists. Each row pushes `PlaylistScreen` for the playlist's
/// detail view (videos + actions). Reuses `PlaylistRow` so the visual matches search/channel.
@available(iOS 17.0, *)
private struct UserPlaylistsScreen: View {
    let playlists: [Playlist]

    var body: some View {
        Group {
            if playlists.isEmpty {
                EmptyStateView(
                    systemImage: "rectangle.stack",
                    title: "No playlists",
                    message: "Playlists you create on YouTube will appear here."
                )
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistScreen(playlistID: playlist.id)
                        } label: {
                            PlaylistRow(playlist: playlist, showsMoreMenu: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

