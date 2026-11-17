import Foundation
import SwiftData

/// One entry of the local **watch list** ("Merkliste", Library tab). Kept under its original
/// name — the model used to back "favorites" — so existing rows carry over without a
/// SwiftData migration.
@available(iOS 17.0, *)
@Model
final class FavoriteVideo {
    @Attribute(.unique) var videoID: String
    var title: String
    var channelName: String
    var thumbnailURL: URL?
    var savedAt: Date

    init(
        videoID: String,
        title: String,
        channelName: String,
        thumbnailURL: URL?,
        savedAt: Date = .now
    ) {
        self.videoID = videoID
        self.title = title
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.savedAt = savedAt
    }
}

@available(iOS 17.0, *)
extension FavoriteVideo {
    /// Minimal `Video` for playback and list rows; the channel ID isn't stored.
    var asVideo: Video {
        Video(id: videoID, title: title, channelID: "", channelName: channelName, channelThumbnailURL: nil,
              thumbnailURL: thumbnailURL, duration: nil, viewCount: nil, publishedAt: nil,
              descriptionSnippet: nil, isLive: false, isShort: false)
    }
}
