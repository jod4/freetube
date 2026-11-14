import SwiftUI
import Kingfisher

@available(iOS 17.0, *)
struct ChannelScreen: View {
    @State private var model: ChannelViewModel
    @Environment(PlayerStateManager.self) private var player

    init(channelID: String) {
        _model = State(wrappedValue: ChannelViewModel(channelID: channelID))
    }

    var body: some View {
        // Switching from a hand-rolled VStack-of-NavigationLinks to a real SwiftUI `List` fixes
        // the alignment + missing-text issues the old menu had: the system handles consistent
        // row heights, label icon/text alignment, separators, and chevrons for free.
        List {
            if let details = model.details {
                Section { headerCell(details.channel) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                Section { menuRows(for: details) }
            } else if model.isLoading {
                Section { LoadingView() }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .errorToast(Bindable(model).errorState)
    }

    // MARK: - Header

    /// Banner + avatar + name + subscriber count + subscribe button, rendered as a single
    /// edge-to-edge list row. Uses cleared insets so the banner stretches full width.
    @ViewBuilder
    private func headerCell(_ channel: Channel) -> some View {
        VStack(spacing: 8) {
            if let banner = channel.bannerURL {
                KFImage(banner)
                    .thumbnail(size: CGSize(width: 400, height: 120)) {
                        Color.gray.opacity(0.2)
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(height: 120)
                    .clipped()
            }

            KFImage(channel.thumbnailURL)
                .thumbnail(size: CGSize(width: 88, height: 88)) {
                    Circle().fill(.gray.opacity(0.2))
                }
                .resizable()
                .scaledToFill()
                .frame(width: 88, height: 88)
                .clipShape(Circle())

            Text(channel.name)
                .font(.title2.weight(.bold))

            if let subs = channel.subscriberCount {
                Text("\(formattedCount(subs)) subscribers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await model.toggleSubscribe() }
            } label: {
                Text(channel.isSubscribed ? "Subscribed" : "Subscribe")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(channel.isSubscribed ? Color.gray.opacity(0.2) : Color.red)
                    .foregroundStyle(channel.isSubscribed ? Color.primary : Color.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Menu

    /// One row per tab, custom-built so the count renders as a **detail label** under the title
    /// instead of as a trailing badge (the previous design). The system chevron from the
    /// surrounding NavigationLink supplies the disclosure indicator.
    ///
    /// The counts for the three videos-derived rows (All / Popular / Latest) come from the
    /// channel header's `videoCount` — that's the authoritative total YouTube reports for the
    /// channel. Falling back to the loaded count would tell the user "27 videos" when the
    /// channel actually has 800, which was the original bug.
    @ViewBuilder
    private func menuRows(for details: ChannelDetails) -> some View {
        let totalVideos = details.channel.videoCount

        menuRow(
            title: "All videos",
            subtitle: videosSubtitle(total: totalVideos, loaded: details.videos.items.count, hasMore: details.videos.continuationToken != nil),
            systemImage: "play.rectangle.fill",
            destination: ChannelTabScreen(title: "All videos", kind: .allVideos, model: model)
        )
        menuRow(
            title: "Popular videos",
            subtitle: Text("Most viewed first"),
            systemImage: "flame.fill",
            destination: ChannelTabScreen(title: "Popular", kind: .popular, model: model)
        )
        menuRow(
            title: "Latest videos",
            subtitle: Text("Newest first"),
            systemImage: "clock.fill",
            destination: ChannelTabScreen(title: "Latest", kind: .latest, model: model)
        )
        menuRow(
            title: "Shorts",
            subtitle: countText(details.shorts.items.count, hasMore: details.shorts.continuationToken != nil,
                               plain: { Text("\($0) shorts") }, plus: { Text("\($0)+ shorts") }),
            systemImage: "bolt.fill",
            destination: ChannelTabScreen(title: "Shorts", kind: .shorts, model: model)
        )
        if !details.directs.items.isEmpty {
            menuRow(
                title: "Live",
                subtitle: countText(details.directs.items.count, hasMore: details.directs.continuationToken != nil,
                                   plain: { Text("\($0) streams") }, plus: { Text("\($0)+ streams") }),
                systemImage: "dot.radiowaves.left.and.right",
                destination: ChannelTabScreen(title: "Live", kind: .directs, model: model)
            )
        }
        menuRow(
            title: "Playlists",
            subtitle: countText(details.playlists.items.count, hasMore: details.playlists.continuationToken != nil,
                               plain: { Text("\($0) playlists") }, plus: { Text("\($0)+ playlists") }),
            systemImage: "rectangle.stack.fill",
            destination: ChannelTabScreen(title: "Playlists", kind: .playlists, model: model)
        )
    }

    @ViewBuilder
    private func menuRow<Destination: View>(
        title: LocalizedStringKey,
        subtitle: Text,
        systemImage: String,
        destination: Destination
    ) -> some View {
        NavigationLink {
            destination
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

    /// Count line for the three videos-derived tabs. If the channel header gave us an
    /// authoritative total, use it; otherwise fall back to the loaded count with a `+` suffix
    /// when there's more to fetch.
    private func videosSubtitle(total: Int?, loaded: Int, hasMore: Bool) -> Text {
        if let total {
            // Abbreviated totals ("1.2K") are pre-formatted strings, so they can't drive plural
            // rules — they're always ≥ 1000, i.e. the "other" plural form anyway.
            return total >= 1_000 ? Text("\(formattedCount(total)) videos") : Text("\(total) videos")
        }
        return countText(loaded, hasMore: hasMore, plain: { Text("\($0) videos") }, plus: { Text("\($0)+ videos") })
    }

    /// Count line for shorts / live / playlists — YouTube doesn't expose totals, so we show the
    /// loaded count, using the `+` variant when pagination has more pages. The closures supply
    /// the literal so each phrase is its own pluralized catalog key.
    private func countText(_ loaded: Int, hasMore: Bool, plain: (Int) -> Text, plus: (Int) -> Text) -> Text {
        hasMore && loaded > 0 ? plus(loaded) : plain(loaded)
    }

    // MARK: - Helpers

    private func formattedCount(_ value: Int) -> String {
        value.compactFormatted
    }
}
