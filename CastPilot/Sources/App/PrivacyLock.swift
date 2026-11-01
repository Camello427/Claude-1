import Foundation
import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// Hides the app behind Face ID / Touch ID / passcode when it comes back from the background.
/// Uses its own window so it also covers any open sheet.
@MainActor
@Observable
final class PrivacyLock {
    private(set) var isLocked = false
    private(set) var isAuthenticating = false
    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private var wasInBackground = true

    func appEnteredBackground(enabled: Bool) {
        wasInBackground = true
        guard enabled else { return }
        isLocked = true
        showWindow()
    }

    func appBecameActive(enabled: Bool) {
        guard enabled else {
            hideWindow()
            return
        }
        if wasInBackground {
            wasInBackground = false
            isLocked = true
            showWindow()
            Task { await unlock() }
        }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on this iPhone, so there's nothing to check against.
            hideWindow()
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock CastPilot") {
                hideWindow()
            }
        } catch {
            // Stay locked; the lock screen has a button to try again.
        }
    }

    private func showWindow() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        w.rootViewController = UIHostingController(rootView: LockScreenView(lock: self))
        w.isHidden = false
        window = w
    }

    private func hideWindow() {
        isLocked = false
        window?.isHidden = true
        window = nil
    }
}

struct LockScreenView: View {
    let lock: PrivacyLock

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("CastPilot is locked")
                .font(.title2.bold())
            Button {
                Task { await lock.unlock() }
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
