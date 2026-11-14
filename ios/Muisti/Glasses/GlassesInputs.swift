import Foundation
import MWDATCore
import MWDATInputs

/// The glasses' own controls (`MWDATInputs`, experimental in DAT 1.0). The capture button keeps
/// Meta's meaning (press = photo, double press = photo / stop video, hold = video); a short
/// press also makes Muisti remember that moment. Push-to-talk is a double tap on the side
/// (touchpad); a single tap stays Meta's play/pause.
@MainActor
final class GlassesInputs {
    /// Double tap on the side (or the action button): push-to-talk.
    var onPress: () -> Void = {}
    /// Short press: the user took a photo; remember this moment too.
    var onCapture: () -> Void = {}

    private var inputs: Inputs?
    private var lastTap: Date?
    private var task: Task<Void, Never>?

    func attach(to session: DeviceSession) {
        guard inputs == nil else { return }
        do throws(DeviceSessionError) {
            guard let newInputs = try session.addInputs(configuration: InputsConfiguration(sources: [.captouch, .captureButton, .actionButton])) else {
                Log.glasses.info("glasses inputs unavailable on this device")
                return
            }
            inputs = newInputs
            let events = newInputs.events
            task = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
            Log.glasses.info("glasses inputs on (double tap on the side = push-to-talk, capture press = remember)")
        } catch {
            Log.glasses.info("glasses inputs not added: \(error.description, privacy: .public)")
        }
    }

    func detach() {
        task?.cancel()
        task = nil
        inputs = nil
    }

    private func handle(_ event: InputEvent) {
        Log.glasses.info("glasses input: \(String(describing: event), privacy: .public)")
        switch event {
        case .select(.captouch, _):
            // The glasses report taps on the side 0.9–2 s apart (field log 14 Nov), so a
            // double tap cannot be told apart reliably: the first tap asks, more taps within
            // 1.5 s belong to the same gesture.
            let now = Date()
            if let last = lastTap, now.timeIntervalSince(last) < 2.5 {
                lastTap = now
                return
            }
            lastTap = now
            onPress()
        case .button(.action, _, _):
            onPress()
        case .capture(.shortPress, _, _):
            onCapture()
        default:
            break
        }
    }
}
