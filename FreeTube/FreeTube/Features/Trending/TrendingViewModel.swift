import Foundation
import Observation
import OSLog

/// Backs the **Trending** tab: the `HomeScreenResponse` feed (personalized when signed in,
/// the curated discovery grid when anonymous) with continuation paging.
@available(iOS 17.0, *)
@Observable
@MainActor
final class TrendingViewModel {
    private(set) var sections: [HomeFeedSection] = []
    private(set) var isLoading: Bool = false
    private(set) var continuationToken: String?
    var errorState: ErrorState?

    private let service: any HomeServicing
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "TrendingViewModel")

    init(service: any HomeServicing = HomeService()) {
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let feed = try await service.fetchHome()
            sections = feed.sections
            continuationToken = feed.continuationToken
        } catch {
            log.error("Trending feed fetch failed: \(String(describing: error), privacy: .public)")
            errorState = ErrorState(from: error)
        }
    }

    func loadMore() async {
        guard let token = continuationToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let feed = try await service.fetchMore(continuation: token)
            sections.append(contentsOf: feed.sections)
            continuationToken = feed.continuationToken
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func refresh() async {
        continuationToken = nil
        sections = []
        await load()
    }
}
