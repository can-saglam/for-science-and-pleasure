import SwiftUI

/// The kill switch's face. Shown full-screen, undismissable, when the server's
/// `min_build` is above this build: the library underneath is frozen and no
/// sync runs until the app is updated. Calm rather than alarming — the user
/// did nothing wrong, their app is just behind.
struct UpdateRequiredView: View {
    @State private var syncStatus = SyncStatus.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            ThemeFill(color: AppBackground.base)

            VStack(spacing: 0) {
                Spacer()

                LogoTitle(height: 34)
                    .padding(.bottom, 36)

                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppBackground.ink.opacity(0.85))
                    .padding(.bottom, 20)

                Text("Time for an update")
                    .font(.post(26, relativeTo: .title))
                    .foregroundStyle(AppBackground.ink)
                    .padding(.bottom, 10)

                Text("This version of Can We Go? can't keep your list in step any more. Update to carry on where you left off — nothing you've saved is lost.")
                    .font(.subheadline)
                    .foregroundStyle(AppBackground.ink.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)

                Spacer()

                Button {
                    if let url = syncStatus.storeURL ?? URL(string: "itms-beta://") {
                        openURL(url)
                    }
                } label: {
                    Text("Update")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .prominentGlass()
                .padding(.horizontal, 28)
                .padding(.bottom, 10)

                Text("Build \(SupabaseSync.buildNumber)")
                    .font(.caption2)
                    .foregroundStyle(AppBackground.ink.opacity(0.35))
                    .padding(.bottom, 8)
            }
        }
        .appColorScheme()
        .interactiveDismissDisabled()
    }
}
