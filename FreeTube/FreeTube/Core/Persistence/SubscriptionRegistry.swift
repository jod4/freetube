import Foundation
import Observation
import OSLog

/// One locally subscribed channel. Carries just enough metadata (name, handle, avatar) to render
/// the channel list and feed chips without a network round-trip per channel.
struct LocalSubscription: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var name: String
    var handle: String?
    var thumbnailURL: URL?
    let subscribedAt: Date
}

/// **Account-free source of truth for the user's channel subscriptions.**
///
/// Subscriptions never touch YouTube — subscribing on a channel page only records the channel
/// here, on this device. `SubscriptionService.fetchFeed` builds the "latest videos" feed by
/// fetching each subscribed channel's Videos tab anonymously (same model as the desktop FreeTube).
/// Signing in or out has no effect on this list.
///
/// **Persistence:** JSON-encoded `[LocalSubscription]` in `UserDefaults` under
/// `com.leshko.freetube.subscriptions`. Older builds stored a bare `[String]` of channel IDs under
/// the same key (an account-backed cache); `load()` migrates that format in place, with empty
/// names that get filled in by `updateMetadata(from:)` on the next feed load.
@available(iOS 17.0, *)
@Observable
@MainActor
final class SubscriptionRegistry {
    static let shared = SubscriptionRegistry()

    nonisolated fileprivate static let defaultsKey = "com.leshko.freetube.subscriptions"

    /// All subscriptions, sorted case-insensitively by channel name.
    private(set) var entries: [LocalSubscription] = []
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "SubscriptionRegistry")

    private init() {
        load()
    }

    // MARK: - Queries

    var ids: Set<String> { Set(entries.map(\.id)) }

    func contains(_ channelID: String) -> Bool {
        entries.contains { $0.id == channelID }
    }

    /// Entries mapped to the domain `Channel` type so existing rows (`ChannelRow`) can render them.
    var channels: [Channel] {
        entries.map { entry in
            Channel(
                id: entry.id,
                // Migrated legacy entries have no name until the next feed load fills it in.
                name: entry.name.isEmpty ? entry.id : entry.name,
                handle: entry.handle,
                thumbnailURL: entry.thumbnailURL,
                bannerURL: nil,
                subscriberCount: nil,
                videoCount: nil,
                isSubscribed: true,
                descriptionText: nil
            )
        }
    }

    /// Non-isolated lookup that bypasses the actor's executor — reads straight from
    /// `UserDefaults`. Use this from non-MainActor contexts like `ChannelService.mapChannel`.
    /// `UserDefaults` is thread-safe, and every mutator calls `persist()`, so the on-disk view
    /// is consistent with `entries`.
    nonisolated static func containsBypassActor(_ channelID: String) -> Bool {
        decode(UserDefaults.standard.data(forKey: defaultsKey))?.contains { $0.id == channelID } ?? false
    }

    // MARK: - Mutations

    /// Records a subscription to `channel`. Idempotent — re-subscribing just refreshes metadata.
    func add(_ channel: Channel) {
        guard !channel.id.isEmpty else { return }
        if contains(channel.id) {
            updateMetadata(from: channel)
            return
        }
        entries.append(LocalSubscription(
            id: channel.id,
            name: channel.name,
            handle: channel.handle,
            thumbnailURL: channel.thumbnailURL,
            subscribedAt: Date()
        ))
        sortAndPersist()
        log.info("[subs-reg] add \(channel.id, privacy: .public) — total=\(self.entries.count, privacy: .public)")
    }

    /// Removes the subscription to `channelID`. Idempotent.
    func remove(_ channelID: String) {
        let before = entries.count
        entries.removeAll { $0.id == channelID }
        guard entries.count != before else { return }
        persist()
        log.info("[subs-reg] remove \(channelID, privacy: .public) — total=\(self.entries.count, privacy: .public)")
    }

    /// Refreshes name / handle / avatar for an existing subscription (channels rename, swap
    /// avatars, and migrated entries start out nameless). No-op for unknown channels or when
    /// nothing changed, so feed loads don't rewrite `UserDefaults` needlessly.
    func updateMetadata(from channel: Channel) {
        guard let index = entries.firstIndex(where: { $0.id == channel.id }) else { return }
        var entry = entries[index]
        if !channel.name.isEmpty { entry.name = channel.name }
        if let handle = channel.handle, !handle.isEmpty { entry.handle = handle }
        if let thumb = channel.thumbnailURL { entry.thumbnailURL = thumb }
        guard entry != entries[index] else { return }
        entries[index] = entry
        sortAndPersist()
    }

    // MARK: - Persistence

    private func load() {
        let data = UserDefaults.standard.data(forKey: Self.defaultsKey)
        if let decoded = Self.decode(data) {
            entries = decoded
        } else if let data, let legacyIDs = try? JSONDecoder().decode([String].self, from: data) {
            // Legacy format: bare channel IDs. Migrate with placeholder metadata.
            entries = legacyIDs.filter { !$0.isEmpty }.map {
                LocalSubscription(id: $0, name: "", handle: nil, thumbnailURL: nil, subscribedAt: Date())
            }
            persist()
            log.info("[subs-reg] migrated \(self.entries.count, privacy: .public) legacy channel IDs")
        } else {
            entries = []
        }
        entries.sort(by: Self.byName)
        log.info("[subs-reg] loaded \(self.entries.count, privacy: .public) subscriptions")
    }

    private func sortAndPersist() {
        entries.sort(by: Self.byName)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    nonisolated private static func decode(_ data: Data?) -> [LocalSubscription]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([LocalSubscription].self, from: data)
    }

    nonisolated private static func byName(_ lhs: LocalSubscription, _ rhs: LocalSubscription) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
