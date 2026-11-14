#if DEBUG
import CoreTransferable
import MWDATCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// MockDeviceKit controls plus a button for every row of the brief's §7 error table.
struct DebugMenu: View {
    let controller: CaptureController
    @Bindable var mock: MockDeviceController

    @State private var pickedVideo: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var battery: Double = 80
    @State private var sessionsPath = ""

    var body: some View {
        Form {
            Section {
                if mock.isEnabled {
                    LabeledContent("Status", value: mock.isPaired ? "Ray-Ban Meta paired" : "Enabled, not paired")
                    if !mock.isPaired { Button("Pair Ray-Ban Meta") { mock.pair() } }
                    Button("Turn off MockDeviceKit", role: .destructive) {
                        Task {
                            await controller.stop()
                            await mock.disable()
                        }
                    }
                } else {
                    Button("Turn on mock glasses (registered + permitted)") {
                        mock.quickStart()
                        controller.config.sourceKind = .glasses
                    }
                    Button("Turn on mock glasses (unregistered, no permission)") {
                        mock.quickStart(registered: false, permissionsGranted: false)
                        controller.config.sourceKind = .glasses
                    }
                }
            } header: {
                Text("MockDeviceKit")
            } footer: {
                Text("Once on, the app connects to the mock glasses through the same SDK calls. Start recording from the main screen.")
            }

            if mock.isPaired {
                Section("Camera feed") {
                    LabeledContent("Current", value: mock.feedLabel)
                    Button("Bundled sign video") { mock.useBundledDemo() }
                    Button("iPhone rear camera (live)") { mock.usePhoneCamera() }
                    PhotosPicker("Choose video from Photos", selection: $pickedVideo, matching: .videos)
                    Button("Choose video from Files") { showFileImporter = true }
                    if mock.isImporting { ProgressView("Converting to HEVC…") }
                    Text("Video must be H.265; otherwise it is converted automatically. If the stream is already running, restart it to use the new feed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Device state") {
                    Toggle("Powered on", isOn: Binding(get: { mock.isPoweredOn }, set: { mock.setPower($0) }))
                    Toggle("Hinge open", isOn: Binding(get: { mock.isUnfolded }, set: { mock.setUnfolded($0) }))
                    Toggle("Worn", isOn: Binding(get: { mock.isDonned }, set: { mock.setDonned($0) }))
                    Button("Tap temple (pause/resume stream)") { mock.tap() }
                    VStack(alignment: .leading) {
                        Text("Battery: \(Int(battery))%")
                        Slider(value: $battery, in: 0...100, step: 1) { editing in
                            if !editing { mock.setBattery(Int(battery)) }
                        }
                    }
                    Picker("Thermal", selection: Binding(get: { mock.thermal }, set: { mock.setThermal($0) })) {
                        Text("normal").tag(ThermalLevel.none)
                        Text("warm").tag(ThermalLevel.moderate)
                        Text("hot").tag(ThermalLevel.severe)
                        Text("critical").tag(ThermalLevel.critical)
                    }
                }

                Section("Error scenarios") {
                    Button("Deny camera permission") { mock.denyCamera() }
                    Button("Grant camera permission") { mock.grantCamera() }
                    Button("Fail the next photo") { mock.simulateCaptureFailure() }
                    Text("Background: go to the Home Screen while recording; 'Resume' should appear when you return. Hinge/worn/battery controls are above.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Data") {
                Button("Delete all memories", role: .destructive) {
                    Task { await controller.deleteAllMemories() }
                }
                #if DEBUG
                Button("Delete memories and load sample photos") {
                    Task {
                        await controller.deleteAllMemories()
                        _ = await controller.ingestFolder("ingest")
                    }
                }
                Text("Samples: Documents/ingest (manifest.json + photos). They go through the real pipeline: OCR, blurring, episodes, Nemotron.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
                Text("Raw dataset (if on): Files > On My iPhone > Muisti > sessions").font(.footnote)
                if !sessionsPath.isEmpty {
                    Text(sessionsPath).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }

            if let error = mock.lastError {
                Section("Last error") { Text(error).foregroundStyle(.danger) }
            }
        }
        .navigationTitle("Mock glasses")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            battery = Double(mock.batteryLevel)
            sessionsPath = (try? SessionRecorder.sessionsRoot.path) ?? ""
        }
        .onChange(of: pickedVideo) { _, item in
            guard let item else { return }
            Task {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    await mock.importVideo(from: movie.url)
                } else {
                    mock.lastError = "Couldn't load the video."
                }
                pickedVideo = nil
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result {
                Task { await mock.importVideo(from: url) }
            }
        }
    }
}

/// Video handed over by PhotosPicker, copied to a temp file we own.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}
#endif
