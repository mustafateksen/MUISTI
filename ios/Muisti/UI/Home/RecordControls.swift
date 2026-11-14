import SwiftUI

/// Start / stop / resume, plus a manual "capture now" while recording.
struct RecordControls: View {
    let controller: CaptureController

    private var isRecording: Bool { controller.isRunning && controller.state.isActive }

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.s) {
                    primaryButton
                    captureButton
                }
                VStack(spacing: Theme.Spacing.s) {
                    primaryButton
                    captureButton
                }
            }

            if let notice = controller.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(5))
                        if controller.notice == notice { controller.notice = nil }
                    }
            }
        }
        .animation(Theme.Motion.standard, value: controller.notice)
        .sensoryFeedback(trigger: isRecording) { _, recording in
            recording ? .start : .stop
        }
    }

    private var primaryButton: some View {
        Button(action: toggleRecording) {
            Label(primaryTitle, systemImage: isRecording ? "stop.fill" : "record.circle")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(isRecording ? .danger : .accentColor)
    }

    private var captureButton: some View {
        Button(action: captureNow) {
            Label("Capture now", systemImage: "camera.shutter.button")
                .font(.headline)
                .frame(minHeight: 34)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(controller.state != .running || controller.glasses.isCapturingStill)
        .fixedSize()
    }

    private var primaryTitle: String {
        switch controller.state {
        case .paused where controller.isRunning: return "Resume"
        case _ where isRecording: return "Stop"
        default: return "Start recording"
        }
    }

    private func toggleRecording() {
        Task {
            if isRecording {
                await controller.stop()
            } else {
                await controller.start()
            }
        }
    }

    private func captureNow() {
        Task { await controller.captureNow() }
    }
}
