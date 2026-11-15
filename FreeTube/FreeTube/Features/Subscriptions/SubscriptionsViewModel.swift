import Foundation
import Observation

/// Drives `SubscriptionsScreen`: the channel chips (straight from the local
/// `SubscriptionRegistry`, so they update the moment you subscribe elsewhere) and the merged
/// latest-videos feed built by `SubscriptionService`. No account involved.
@available(iOS 17.0, *)
@Observable
@MainActor
final class SubscriptionsViewModel {
    private(set) var feedVideos: [Video] = []
    private(set) var isLoading: Bool = false
    /// Number of channels that failed to load in the last refresh (shown as a footnote).
    private(set) var failedChannelCount: Int = 0
    var errorState: ErrorState?

    private let service: any SubscriptionServicing
    private let registry = SubscriptionRegistry.shared

    init(service: any SubscriptionServicing = SubscriptionService()) {
        self.service = service
    }

    var channels: [Channel] { registry.channels }

    var hasSubscriptions: Bool { !registry.entries.isEmpty }

    /// Changes whenever the subscription set changes — the screen keys its `.task` on this so the
    /// feed reloads after subscribing / unsubscribing.
    var subscriptionKey: String { registry.entries.map(\.id).sorted().joined(separator: ",") }

    func load(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let feed = try await service.fetchFeed(forceRefresh: forceRefresh)
            feedVideos = feed.videos
            failedChannelCount = feed.failedChannelCount
        } catch {
            errorState = ErrorState(from: error)
        }
    }
}
