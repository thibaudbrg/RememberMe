import LocalAuthentication
import SwiftUI

/// Shown when `Settings.biometricLockEnabled` is on and the user hasn't authenticated this
/// session yet. Prompts for Face ID / Touch ID, with a retry path if the user cancels.
///
/// The DB itself is *not* re-encrypted behind biometrics — this is a UI gate. The data still
/// lives behind the SQLCipher key in the Keychain (which has its own `WhenUnlocked` protection).
struct LockedView: View {
    let onUnlock: () -> Void

    @State private var status: Status = .idle
    @State private var errorMessage: String?

    enum Status: Equatable {
        case idle
        case prompting
        case failed
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "faceid")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text("RememberMe is locked")
                .font(.title2.weight(.semibold))
            Text("Authenticate to view your history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button {
                Task { await authenticate() }
            } label: {
                Label(status == .failed ? "Try again" : "Unlock", systemImage: "lock.open")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task {
            // Auto-prompt on appear so the user doesn't have to tap the button on first launch.
            if status == .idle { await authenticate() }
        }
    }

    @MainActor
    private func authenticate() async {
        status = .prompting
        errorMessage = nil

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var configError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &configError) else {
            errorMessage = configError?.localizedDescription ?? "Biometric authentication is unavailable on this device."
            status = .failed
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your timeline"
            )
            if success {
                onUnlock()
            } else {
                status = .failed
            }
        } catch {
            errorMessage = error.localizedDescription
            status = .failed
        }
    }
}

#Preview {
    LockedView { }
}
