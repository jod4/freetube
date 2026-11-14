import SwiftUI
import Observation

/// Alphabetical list of every locally subscribed channel (no account involved). Each row pushes
/// `ChannelScreen`; swipe a row to unsubscribe.
///
/// Named distinctly from `SubscriptionsScreen` (the *feed of latest videos*) — file names must be
/// unique within the Xcode target.
@available(iOS 17.0, *)
struct SubscribedChannelsScreen: View {
    @State private var model = SubscribedChannelsViewModel()

    var body: some View {
        Group {
            if model.channels.isEmpty {
                EmptyStateView(
                    systemImage: "person.2.fill",
                    title: "No subscriptions",
                    message: "Tap Subscribe on any channel page. Subscriptions are stored on this device only — no account needed."
                )
            } else {
                List {
                    ForEach(model.channels) { channel in
                        NavigationLink {
                            ChannelScreen(channelID: channel.id)
                        } label: {
                            ChannelRow(channel: channel)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.unsubscribe(channel) }
                            } label: {
                                Label("Unsubscribe", systemImage: "person.badge.minus")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Channels you follow")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@available(iOS 17.0, *)
@Observable
@MainActor
final class SubscribedChannelsViewModel {
    private let service: any SubscriptionServicing
    private let registry = SubscriptionRegistry.shared

    init(service: any SubscriptionServicing = SubscriptionService()) {
        self.service = service
    }

    /// Read straight from the observable registry so the list reflects subscribe / unsubscribe
    /// actions from anywhere in the app without a reload.
    var channels: [Channel] { registry.channels }

    func unsubscribe(_ channel: Channel) async {
        await service.unsubscribe(channelID: channel.id)
    }
}
