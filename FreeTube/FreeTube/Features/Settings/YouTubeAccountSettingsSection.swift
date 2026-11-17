import SwiftUI
import Kingfisher

/// Settings → **YouTube account**. The app is account-free by default; this section is where
/// sign-in lives now (it used to sit on top of the old Library tab).
///
/// - Switch off (default): no sign-in UI anywhere, no cookies. Turning it off signs out and
///   wipes cookies + login web data, so the app is really anonymous again.
/// - Switch on: "Sign in to YouTube" (or the account + Sign out once signed in). Signed in,
///   the Library tab gains its YouTube section and "Add to playlist" appears in video menus.
@available(iOS 17.0, *)
struct YouTubeAccountSettingsSection: View {
    @AppStorage(UserPreferences.useYouTubeAccountKey) private var useYouTubeAccount = false
    @State private var accountModel = AccountViewModel()
    @State private var showingLogin = false

    var body: some View {
        Section {
            Toggle("Use YouTube account", isOn: $useYouTubeAccount)
            if useYouTubeAccount {
                if let info = accountModel.info {
                    HStack(spacing: 12) {
                        KFImage(info.avatarURL)
                            .thumbnail(size: CGSize(width: 40, height: 40)) {
                                Circle().fill(.gray.opacity(0.2))
                            }
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(verbatim: info.displayName).font(.headline)
                            if let handle = info.handle, !handle.isEmpty {
                                Text(verbatim: handle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Sign out") {
                            Task { await accountModel.signOut() }
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Button {
                        showingLogin = true
                    } label: {
                        Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        } header: {
            Text("YouTube account")
        } footer: {
            Text("FreeTube works without an account: subscriptions, watch list and history stay on this device. Turn this on to sign in and see your YouTube history, playlists, liked videos and Watch later in the Library. Turning it off signs you out.")
        }
        .task(id: useYouTubeAccount) {
            if useYouTubeAccount {
                await accountModel.load()
            }
        }
        .onChange(of: useYouTubeAccount) { _, isOn in
            if !isOn {
                Task { await accountModel.signOut() }
            }
        }
        .sheet(isPresented: $showingLogin) {
            LoginScreen()
                .onDisappear {
                    // Cookies landed → the next `fetchAccountInfo` returns the account.
                    Task { await accountModel.load() }
                }
        }
    }
}
