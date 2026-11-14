import SwiftUI
import Kingfisher

/// Latest videos from the user's local (account-free) subscriptions, with a horizontal strip of
/// channel avatars on top. Pushed from the Library tab, so it has no `NavigationStack` of its own.
@available(iOS 17.0, *)
struct SubscriptionsScreen: View {
    @State private var model = SubscriptionsViewModel()
    @Environment(PlayerStateManager.self) private var player

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.hasSubscriptions {
                    channelStrip
                    SectionHeader(title: "Latest from your subscriptions")
                    ForEach(model.feedVideos) { video in
                        VideoCard(video: video, onTap: { player.load(video) }, showsMoreMenu: true)
                    }
                    if model.isLoading && model.feedVideos.isEmpty {
                        LoadingView()
                    } else if model.feedVideos.isEmpty && !model.isLoading {
                        EmptyStateView(systemImage: "rectangle.stack.person.crop",
                                       title: "Nothing new",
                                       message: "Subscribe to channels to see their latest videos here.")
                    }
                    if model.failedChannelCount > 0 && !model.isLoading {
                        Text("\(model.failedChannelCount) channels couldn't be loaded. Pull to refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                } else {
                    EmptyStateView(systemImage: "person.2.fill",
                                   title: "No subscriptions",
                                   message: "Tap Subscribe on any channel page. Subscriptions are stored on this device only — no account needed.")
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SubscribedChannelsScreen()
                } label: {
                    Label("Channels you follow", systemImage: "person.2")
                }
                .disabled(!model.hasSubscriptions)
            }
        }
        .refreshable { await model.load(forceRefresh: true) }
        .task(id: model.subscriptionKey) { await model.load() }
        .errorToast(Bindable(model).errorState)
    }

    // MARK: - Channel strip

    private var channelStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(model.channels) { channel in
                    NavigationLink {
                        ChannelScreen(channelID: channel.id)
                    } label: {
                        channelChip(channel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func channelChip(_ channel: Channel) -> some View {
        VStack(spacing: 6) {
            KFImage(channel.thumbnailURL)
                .thumbnail(size: CGSize(width: 64, height: 64)) {
                    Circle().fill(.gray.opacity(0.2))
                }
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
            Text(verbatim: channel.name).font(.caption).lineLimit(1).frame(maxWidth: 80)
        }
    }
}
