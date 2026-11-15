import SwiftUI
import Kingfisher

/// Vertical "feed" video card — used in Trending, Subscriptions, and every multi-column
/// `VideoGrid`.
///
/// Set `showsMoreMenu: true` to render the trailing ellipsis Menu (open in browser, copy URL,
/// favorites, add to playlist, downloads) on the metadata row. The Menu sits as a sibling of
/// the card's main tap target so its taps don't trigger `onTap`.
@available(iOS 17.0, *)
struct VideoCard: View {
    let video: Video
    var onTap: () -> Void = {}
    var showsMoreMenu: Bool = false
    /// Grid style: rounded thumbnail and no own side padding, because the surrounding grid
    /// already insets the cards. `false` = full-bleed single-column look.
    var isInset: Bool = false

    @Environment(\.displayScale) private var displayScale

    /// Channel name plus the playback count and relative upload date. Joined by middle dots so
    /// the line reads naturally and any missing segment is dropped without leaving stray
    /// separators ("Channel" / "Channel • 1.2M views" / "Channel • 1.2M views • 3 days ago").
    private var metadataLine: String {
        let parts = [video.channelName, video.viewCountString, video.publishedRelative ?? ""]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onTap) {
                thumbnail
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(video.title), \(video.channelName)"))

            // Metadata row is split into its own HStack so the ellipsis Menu can live as a
            // sibling of the title/avatar tap target (which still routes to `onTap`). Nesting
            // the Menu inside the outer Button would route taps to playback instead of to the
            // Menu, since SwiftUI's outer Button consumes the gesture first.
            metadataRow
        }
    }

    /// Strictly 16:9 whatever the source image is (Shorts and old 4:3 uploads would
    /// otherwise make the card taller): the `Color.clear` box fixes the frame from the width,
    /// the image only fills it as an overlay. Decoded at ~480×270 pt × screen scale, which
    /// covers a 2–3 column iPad card and a single-column iPhone card without wasting memory.
    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .aspectRatio(16/9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    KFImage(video.thumbnailURL)
                        .thumbnail(size: CGSize(width: 480, height: 270), scale: displayScale) {
                            Color.gray.opacity(0.2)
                        }
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: isInset ? 10 : 0))

            if !video.durationString.isEmpty {
                Text(video.durationString)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.75))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
    }

    private var metadataRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 12) {
                    KFImage(video.channelThumbnailURL)
                        .thumbnail(size: CGSize(width: 36, height: 36)) {
                            Circle().fill(.gray.opacity(0.2))
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        // Always two lines tall, so neighbouring cards in a grid row
                        // line up and every row has the same height.
                        Text(video.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2, reservesSpace: true)
                        Text(metadataLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsMoreMenu {
                VideoMoreActionsMenu(video: video)
            }
        }
        .padding(.horizontal, isInset ? 0 : 16)
    }
}
