import MWDATCore
import SwiftUI

@main
struct MuistiApp: App {
    @State private var config: AppConfig
    @State private var wearables: WearablesController
    @State private var controller: CaptureController

    init() {
        do {
            try Wearables.configure()
        } catch {
            NSLog("[Muisti] Wearables.configure failed: \(error)")
        }
        let config = AppConfig()
        let wearables = WearablesController()
        _config = State(wrappedValue: config)
        _wearables = State(wrappedValue: wearables)
        _controller = State(wrappedValue: CaptureController(config: config, wearables: wearables))
    }

    var body: some Scene {
        WindowGroup {
            HomeView(controller: controller, config: config, wearables: wearables)
                .onOpenURL { url in
                    // Only Meta AI callbacks go to the SDK.
                    guard
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                        components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
                    else { return }
                    Task { await wearables.handleOpenURL(url) }
                }
        }
    }
}
