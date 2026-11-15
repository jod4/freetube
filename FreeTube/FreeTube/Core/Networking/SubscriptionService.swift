import Foundation
import OSLog

struct SubscriptionFeed: Sendable {
    let videos: [Video]
    /// Channels whose Videos tab couldn't be fetched this round (network error, removed channel).
    /// The feed is still returned with everything that did load.
    let failedChannelCount: Int
}

protocol SubscriptionServicing: Sendable {
    func fetchFeed(forceRefresh: Bool) async throws -> SubscriptionFeed
    func subscribedChannels() async -> [Channel]
    func subscribe(to channel: Channel) async
    func unsubscribe(channelID: String) async
}

/// **Account-free subscriptions.** Subscribe / unsubscribe only write to the on-device
/// `SubscriptionRegistry` — nothing is sent to YouTube and no sign-in is needed.
///
/// The feed is assembled client-side: for every subscribed channel we fetch the first page of its
/// Videos tab anonymously via `ChannelService.fetchLatestVideos(channelID:)`, merge, and sort by
/// the approximate age parsed from YouTube's relative "time posted" text (`RelativeAgeParser`).
/// That's one or two browse requests per channel, run with bounded concurrency, and the merged
/// result is cached in memory for `FeedCache.ttl` so tab switches don't refetch.
///
/// Deliberately does *not* use `AccountSubscriptionsFeedResponse` / `AccountSubscriptionsResponse`
/// / `SubscribeChannelResponse` / `UnsubscribeChannelResponse` — those require cookies.
final class SubscriptionService: SubscriptionServicing {
    /// Parallel channel fetches. High enough to keep a 100-channel refresh in the seconds range,
    /// low enough not to look like a burst to YouTube's rate limiter.
    private static let maxConcurrentFetches = 6
    /// Videos taken from each channel's first page before merging.
    private static let videosPerChannel = 15
    /// Hard cap on the merged feed length.
    private static let maxFeedLength = 300

    private let channels: any ChannelServicing
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "SubscriptionService")

    nonisolated init(channels: any ChannelServicing = ChannelService()) {
        self.channels = channels
    }

    // MARK: - Subscriptions

    func subscribedChannels() async -> [Channel] {
        SubscriptionRegistry.shared.channels
    }

    /// Records a local subscription. Never fails — there's no remote call.
    func subscribe(to channel: Channel) async {
        log.info("[subs] subscribe channelID=\(channel.id, privacy: .public)")
        SubscriptionRegistry.shared.add(channel)
    }

    func unsubscribe(channelID: String) async {
        log.info("[subs] unsubscribe channelID=\(channelID, privacy: .public)")
        SubscriptionRegistry.shared.remove(channelID)
    }

    // MARK: - Feed

    /// Latest videos across all subscribed channels, newest first. Served from the in-memory cache
    /// when it is fresh and was built for the same set of channels, unless `forceRefresh`.
    /// Throws only when there are subscriptions and *every* channel fetch failed.
    func fetchFeed(forceRefresh: Bool) async throws -> SubscriptionFeed {
        let subscriptions = SubscriptionRegistry.shared.entries
        guard !subscriptions.isEmpty else {
            return SubscriptionFeed(videos: [], failedChannelCount: 0)
        }
        let ids = Set(subscriptions.map(\.id))
        if !forceRefresh, let cached = await FeedCache.shared.feed(for: ids) {
            return cached
        }

        log.info("[subs] building feed for \(subscriptions.count, privacy: .public) channels")
        let started = Date()
        let results = await fetchAll(channelIDs: subscriptions.map(\.id))

        var ranked: [RankedVideo] = []
        var failed = 0
        var lastError: Error?
        for result in results {
            switch result {
            case .success(let latest):
                SubscriptionRegistry.shared.updateMetadata(from: latest.channel)
                for (index, video) in latest.videos.prefix(Self.videosPerChannel).enumerated() {
                    ranked.append(RankedVideo(
                        video: video,
                        age: RelativeAgeParser.age(from: video.publishedRelative),
                        positionInChannel: index
                    ))
                }
            case .failure(let error):
                failed += 1
                lastError = error
            }
        }

        if failed == results.count, let lastError {
            log.error("[subs] feed: all \(failed, privacy: .public) channel fetches failed")
            throw lastError
        }

        ranked.sort(by: RankedVideo.newerFirst)
        let feed = SubscriptionFeed(
            videos: ranked.prefix(Self.maxFeedLength).map(\.video),
            failedChannelCount: failed
        )
        await FeedCache.shared.store(feed, for: ids)
        log.info("[subs] feed built: \(feed.videos.count, privacy: .public) videos, \(failed, privacy: .public) failed, \(Date().timeIntervalSince(started), privacy: .public)s")
        return feed
    }

    /// Fetches every channel's latest videos with at most `maxConcurrentFetches` in flight.
    private func fetchAll(channelIDs: [String]) async -> [Result<ChannelLatestVideos, Error>] {
        let service = channels
        return await withTaskGroup(of: Result<ChannelLatestVideos, Error>.self) { group in
            var pending = channelIDs.makeIterator()
            var results: [Result<ChannelLatestVideos, Error>] = []
            results.reserveCapacity(channelIDs.count)
            var inFlight = 0

            while true {
                while inFlight < Self.maxConcurrentFetches, let id = pending.next() {
                    inFlight += 1
                    group.addTask {
                        do {
                            return .success(try await service.fetchLatestVideos(channelID: id))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                guard let result = await group.next() else { break }
                inFlight -= 1
                results.append(result)
            }
            return results
        }
    }
}

// MARK: - Ranking

private struct RankedVideo {
    let video: Video
    /// Approximate age in seconds; nil when YouTube's text couldn't be parsed.
    let age: TimeInterval?
    /// Index in the channel's newest-first listing — tie-breaker for equal parsed ages
    /// ("2 days ago" covers a whole day).
    let positionInChannel: Int

    static func newerFirst(_ lhs: RankedVideo, _ rhs: RankedVideo) -> Bool {
        switch (lhs.age, rhs.age) {
        case let (l?, r?) where l != r: return l < r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.positionInChannel < rhs.positionInChannel
        }
    }
}

// MARK: - Cache

/// In-memory cache of the last built feed. Shared across `SubscriptionService` instances (each
/// view model creates its own). Keyed by the exact set of channel IDs so subscribing or
/// unsubscribing invalidates it automatically.
private actor FeedCache {
    static let shared = FeedCache()
    static let ttl: TimeInterval = 15 * 60

    private var entry: (ids: Set<String>, feed: SubscriptionFeed, builtAt: Date)?

    func feed(for ids: Set<String>) -> SubscriptionFeed? {
        guard let entry, entry.ids == ids, Date().timeIntervalSince(entry.builtAt) < Self.ttl else {
            return nil
        }
        return entry.feed
    }

    func store(_ feed: SubscriptionFeed, for ids: Set<String>) {
        entry = (ids, feed, Date())
    }
}
