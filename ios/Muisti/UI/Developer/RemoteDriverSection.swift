#if DEBUG
import SwiftUI

/// Switches the remote driver on from inside the app (no Xcode needed on the other side) and
/// shows where to connect: this phone's address on the Wi-Fi, the port and the token.
struct RemoteDriverSection: View {
    let controller: CaptureController
    @State private var isOn = RemoteDriver.shared != nil
    @State private var address = RemoteDriver.wifiAddress

    var body: some View {
        Section {
            Toggle("Remote driver", isOn: $isOn)
                .onChange(of: isOn) { _, on in
                    RemoteDriver.enabledInApp = on
                    if on {
                        isOn = RemoteDriver.start(controller: controller, port: RemoteDriver.defaultPort, token: RemoteDriver.appToken, speak: false)
                        address = RemoteDriver.wifiAddress
                    } else {
                        RemoteDriver.stop()
                    }
                }
            if isOn {
                LabeledContent("Address") {
                    Text(verbatim: "http://\(address ?? "<this phone's Wi-Fi address>"):\(RemoteDriver.port)")
                        .textSelection(.enabled)
                }
                LabeledContent("Token") {
                    Text(verbatim: RemoteDriver.appToken)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let failure = RemoteDriver.failure {
                Text(verbatim: failure).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text(verbatim: "Remote driver")
        } footer: {
            Text(verbatim: "Lets a computer on the same Wi-Fi show Muisti videos and photos as if the glasses saw them, ask it questions and read what it says. Keep Muisti open in front while it is used; answers are returned as text instead of being spoken. Anyone with the token can read and delete Muisti's memory: switch it off when done.")
        }
    }
}
#endif
