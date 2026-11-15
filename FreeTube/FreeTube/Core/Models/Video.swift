import Foundation

/// Domain model for a YouTube video. Service layer maps YouTubeKit response types into this.
struct Video: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let channelID: String
    let channelName: String
    let channelThumbnailURL: URL?
    let thumbnailURL: URL?
    let duration: TimeInterval?
    let viewCount: Int?
    let publishedAt: Date?
    /// Human-readable "N days ago" string from YouTube's `timePosted` field. We keep this as a
    /// separate display-ready string instead of parsing into a Date because YouTube only returns
    /// relative phrasing here ("3 days ago" / "2 months ago" / "1 year ago") and trying to round-
    /// trip that through a Date would lose precision and re-localize awkwardly.
    let publishedRelative: String?
    let descriptionSnippet: String?
    let isLive: Bool
    let isShort: Bool
}

extension Video {
    /// Forwarding initializer that defaults `publishedRelative` to nil. Keeps the dozen
    /// existing call sites that construct `Video` literally (in VideoService, PlaybackResolver,
    /// LibraryScreen, DownloadsScreen, etc.) compiling without each one being touched — only
    /// places that have a real value (Mappers, channel/playlist backfill) need to pass it.
    init(
        id: String,
        title: String,
        channelID: String,
        channelName: String,
        channelThumbnailURL: URL?,
        thumbnailURL: URL?,
        duration: TimeInterval?,
        viewCount: Int?,
        publishedAt: Date?,
        descriptionSnippet: String?,
        isLive: Bool,
        isShort: Bool
    ) {
        self.init(
            id: id,
            title: title,
            channelID: channelID,
            channelName: channelName,
            channelThumbnailURL: channelThumbnailURL,
            thumbnailURL: thumbnailURL,
            duration: duration,
            viewCount: viewCount,
            publishedAt: publishedAt,
            publishedRelative: nil,
            descriptionSnippet: descriptionSnippet,
            isLive: isLive,
            isShort: isShort
        )
    }
}

extension Video {
    var durationString: String {
        guard let duration else { return "" }
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Localized view-count line ("1.2M views", "1,2 Mio. Aufrufe", "856 views"). Empty when
    /// the API didn't return a count, so callers can hide the label entirely. Counts below 1000
    /// go through the `%lld views` key so plural rules apply ("1 view").
    var viewCountString: String {
        guard let viewCount, viewCount > 0 else { return "" }
        if viewCount < 1_000 {
            return String(localized: "\(viewCount) views")
        }
        return String(localized: "\(viewCount.compactFormatted) views")
    }
}
