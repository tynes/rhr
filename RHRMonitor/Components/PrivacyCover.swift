import SwiftUI

/// Covers the app's content when it isn't in the foreground (so heart rate data doesn't appear in
/// the app switcher) and while the optional app lock is engaged.
///
/// Sheets and dialogs are presented above this cover, so each screen closes its own when the app
/// locks (see the `appLock.isLocked` handlers). In the app-switcher snapshot of an unlocked app, an
/// open sheet can still appear on top.
struct PrivacyCover: View {
    let locked: Bool
    let isAuthenticating: Bool
    let error: String?
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: locked ? "lock.fill" : "heart.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("RHR Monitor").font(.title2.bold())
                if locked {
                    Text("Locked. Bluetooth collection and recording keep running.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                    Button("Unlock", action: unlock)
                        .buttonStyle(.borderedProminent)
                        .disabled(isAuthenticating)
                }
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
