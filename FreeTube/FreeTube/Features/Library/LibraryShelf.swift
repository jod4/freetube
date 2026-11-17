import SwiftUI
import Kingfisher

/// One horizontal row of the Library overview (watch list, history): a header with
/// "See all", then the newest videos as small cards scrolling sideways. Lives inside the
/// Library `List` as a single full-width row.
@available(iOS 17.0, *)
struct LibraryShelf<Destination: View>: View {
    let title: LocalizedStringKey
    let videos: [Video]
    /// Remove action offered in each card's context menu (long press).
    let removeLabel: LocalizedStringKey
    let onRemove: (Video) -> Void
    @ViewBuilder let destination: () -> Destination

    @Environment(PlayerStateManager.self) private var player

    /// The shelf previews; "See all" shows the rest.
    private let previewLimit = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                NavigationLink {
                    destination()
                } label: {
                    HStack(spacing: 2) {
                        Text("See all")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(videos.prefix(previewLimit)) { video in
                        ShelfCard(video: video) { player.load(video) }
                            .contextMenu {
                                Button(role: .destructive) {
                                    onRemove(video)
                                } label: {
                                    Label(removeLabel, systemImage: "minus.circle")
                                }
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Small fixed-width video card for `LibraryShelf`: rounded 16:9 thumbnail, two-line title,
/// channel name.
@available(iOS 17.0, *)
private struct ShelfCard: View {
    let video: Video
    let onTap: () -> Void

    @Environment(\.displayScale) private var displayScale
    private let width: CGFloat = 200

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .frame(width: width, height: width * 9 / 16)
                    .overlay {
                        KFImage(video.thumbnailURL)
                            .thumbnail(size: CGSize(width: width, height: width * 9 / 16), scale: displayScale) {
                                Color.gray.opacity(0.2)
                            }
                            .resizable()
                            .scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(video.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                if !video.channelName.isEmpty {
                    Text(verbatim: video.channelName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
