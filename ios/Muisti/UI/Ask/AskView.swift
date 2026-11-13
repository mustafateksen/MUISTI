import MapKit
import SwiftUI

/// Voice Q&A: push-to-talk, live transcript, answer with GÖRDÜM/BİLMİYORUM label and the
/// evidence frames (time, street, OCR text, map pin) under it.
struct AskView: View {
    let controller: CaptureController
    @Bindable var voice: VoiceAssistant
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    micButton
                    phaseText
                    typedField
                    if let result = voice.lastResult {
                        AnswerCard(result: result, store: controller.store)
                    }
                    if voice.history.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Önceki sorular").font(.headline)
                            ForEach(voice.history.dropFirst()) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.question).font(.subheadline.weight(.semibold))
                                    Text(item.answer).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Sor")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var micButton: some View {
        Button {
            Task { await voice.toggleListening() }
        } label: {
            ZStack {
                Circle()
                    .fill(voice.phase == .listening ? Color.red : Color.accentColor)
                    .frame(width: 132, height: 132)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                Image(systemName: icon)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: voice.phase == .listening || voice.phase == .thinking)
            }
        }
        .buttonStyle(.plain)
        .disabled(voice.phase == .thinking)
        .accessibilityLabel(voice.phase == .listening ? "Dinlemeyi bitir" : "Soru sor")
        .padding(.top, 8)
    }

    private var icon: String {
        switch voice.phase {
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        default: return "mic.fill"
        }
    }

    @ViewBuilder
    private var phaseText: some View {
        VStack(spacing: 6) {
            switch voice.phase {
            case .idle:
                Text("Dokun ve sor: “Geçtiğimiz sokaktaki dişçinin numarası neydi?”")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            case .listening:
                Text("Dinliyorum…").font(.headline)
            case .thinking:
                Text("Hafızada arıyorum…").font(.headline)
            case .speaking:
                Text("Cevap okunuyor").font(.headline)
            case .failed(let message):
                Text(message).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            if !voice.transcript.isEmpty {
                Text("“\(voice.transcript)”").font(.title3.weight(.medium)).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .font(.subheadline)
    }

    private var typedField: some View {
        HStack {
            TextField("Ya da yaz…", text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(send)
            Button("Sor", action: send)
                .buttonStyle(.bordered)
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || voice.isBusy)
        }
    }

    private func send() {
        let q = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        typed = ""
        typing = false
        Task { await voice.ask(q) }
    }
}

struct AnswerCard: View {
    let result: AskResult
    let store: MemoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(result.label.display)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(result.label == .seen ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(result.label == .seen ? .green : .orange)
                Spacer()
                Text("\(result.latencyMs) ms\(result.usedAI ? " · Nemotron" : " · yerel")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(result.answer).font(.title3.weight(.semibold))
            if let note = result.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.evidence) { hit in
                EvidenceRow(hit: hit, store: store)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct EvidenceRow: View {
    let hit: MemoryHit
    let store: MemoryStore

    var body: some View {
        let r = hit.record
        VStack(alignment: .leading, spacing: 8) {
            KeyframeImage(url: store.frameURL(r), maxPixel: 900)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(r.seenAt.formatted(date: .abbreviated, time: .shortened))
                if let street = r.street {
                    Image(systemName: "mappin")
                    Text(street)
                }
                if let d = hit.distanceMeters { Text(String(format: "· %.0f m", d)) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !r.ocrText.isEmpty {
                Text(r.ocrText.replacingOccurrences(of: "\n", with: " · "))
                    .font(.caption.monospaced())
                    .lineLimit(4)
            }
            if let lat = r.latitude, let lon = r.longitude {
                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 400, longitudinalMeters: 400))) {
                    Marker(r.name ?? r.kind ?? "Görüldü", coordinate: coordinate)
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }
        }
    }
}

/// Loads a stored keyframe off the main thread, downsampled.
struct KeyframeImage: View {
    let url: URL
    var maxPixel = 600
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: url) {
            let url = url, maxPixel = maxPixel
            image = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url), let cg = ImageData.thumbnail(data, maxPixel: maxPixel) else { return nil }
                return UIImage(cgImage: cg)
            }.value
        }
    }
}
