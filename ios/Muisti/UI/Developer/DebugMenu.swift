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
                    LabeledContent("Durum", value: mock.isPaired ? "Ray-Ban Meta eşleşti" : "Etkin, eşleşmedi")
                    if !mock.isPaired { Button("Ray-Ban Meta eşleştir") { mock.pair() } }
                    Button("MockDeviceKit'i kapat", role: .destructive) {
                        Task {
                            await controller.stop()
                            await mock.disable()
                        }
                    }
                } else {
                    Button("Sahte gözlüğü aç (kayıtlı + izinli)") {
                        mock.quickStart()
                        controller.config.sourceKind = .glasses
                    }
                    Button("Sahte gözlüğü aç (kayıtsız, izinsiz)") {
                        mock.quickStart(registered: false, permissionsGranted: false)
                        controller.config.sourceKind = .glasses
                    }
                }
            } header: {
                Text("MockDeviceKit")
            } footer: {
                Text("Açıldıktan sonra uygulama aynı SDK çağrılarıyla sahte gözlüğe bağlanır. Ana ekrandan Kaydı başlat.")
            }

            if mock.isPaired {
                Section("Kamera beslemesi") {
                    LabeledContent("Şu an", value: mock.feedLabel)
                    Button("Paketteki tabela videosu") { mock.useBundledDemo() }
                    Button("Telefonun arka kamerası (canlı)") { mock.usePhoneCamera() }
                    PhotosPicker("Fotoğraflar'dan video seç", selection: $pickedVideo, matching: .videos)
                    Button("Dosyalar'dan video seç") { showFileImporter = true }
                    if mock.isImporting { ProgressView("HEVC'ye çevriliyor…") }
                    Text("Video h.265 olmalı; değilse otomatik çevrilir. Akış zaten açıksa yeni besleme için akışı yeniden başlat.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Cihaz durumu") {
                    Toggle("Güç açık", isOn: Binding(get: { mock.isPoweredOn }, set: { mock.setPower($0) }))
                    Toggle("Menteşe açık", isOn: Binding(get: { mock.isUnfolded }, set: { mock.setUnfolded($0) }))
                    Toggle("Takılı", isOn: Binding(get: { mock.isDonned }, set: { mock.setDonned($0) }))
                    Button("Sapa dokun (akışı duraklat/sürdür)") { mock.tap() }
                    VStack(alignment: .leading) {
                        Text("Pil: %\(Int(battery))")
                        Slider(value: $battery, in: 0...100, step: 1) { editing in
                            if !editing { mock.setBattery(Int(battery)) }
                        }
                    }
                    Picker("Isı", selection: Binding(get: { mock.thermal }, set: { mock.setThermal($0) })) {
                        Text("normal").tag(ThermalLevel.none)
                        Text("ılık").tag(ThermalLevel.moderate)
                        Text("sıcak").tag(ThermalLevel.severe)
                        Text("kritik").tag(ThermalLevel.critical)
                    }
                }

                Section("Hata senaryoları") {
                    Button("Kamera iznini reddet") { mock.denyCamera() }
                    Button("Kamera iznini ver") { mock.grantCamera() }
                    Button("Sonraki fotoğraf başarısız olsun") { mock.simulateCaptureFailure() }
                    Text("Arka plan: kayıt sürerken ana ekrana dön; dönüşte 'Devam et' görünmeli. Menteşe/takma/pil satırları yukarıda.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Veri") {
                Button("Tüm hafızayı sil", role: .destructive) {
                    Task { await controller.deleteAllMemories() }
                }
                Text("Ham veri seti (açıksa): Dosyalar > Bu iPhone'da > Muisti > sessions").font(.footnote)
                if !sessionsPath.isEmpty {
                    Text(sessionsPath).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }

            if let error = mock.lastError {
                Section("Son hata") { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Sahte gözlük")
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
                    mock.lastError = "Video yüklenemedi."
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
