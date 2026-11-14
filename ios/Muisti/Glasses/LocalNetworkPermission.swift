import Foundation
import Network
import Observation
import UIKit

/// The Meta SDK moves photos and video over Wi-Fi only if iOS lets Muisti use the local
/// network; otherwise it silently falls back to Bluetooth Classic (10+ s per 12 MP still).
/// A short Bonjour browse for the SDK's `_bonjour._tcp` service triggers the system prompt if
/// it has not been answered, and tells us when the permission was denied.
@Observable
@MainActor
final class LocalNetworkPermission {
    static let shared = LocalNetworkPermission()

    /// true = the user turned Local Network off for Muisti.
    private(set) var denied = false
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var activeTask: Task<Void, Never>?

    private init() {
        // Back from Settings (or from the prompt): look again if it was off.
        activeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard let self, self.denied else { continue }
                self.check()
            }
        }
    }

    func check() {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: "_bonjour._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { @Sendable state in
            Task { @MainActor in LocalNetworkPermission.shared.handle(state) }
        }
        browser.start(queue: DispatchQueue(label: "fi.junction.muisti.localnetwork"))
        self.browser = browser
        // The answer (or the prompt) comes within seconds; no need to keep browsing.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.browser?.cancel()
            self?.browser = nil
        }
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            denied = false
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                denied = true
                Log.glasses.info("local network permission denied: glasses fall back to Bluetooth")
            }
        default:
            break
        }
    }
}
