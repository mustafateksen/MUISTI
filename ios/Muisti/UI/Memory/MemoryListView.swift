import MapKit
import SwiftUI

/// What is stored on this phone: every kept frame (blurred), what was read, what Nemotron
/// made of it. Swipe to delete, "son 10 dakikayı unut", delete all.
struct MemoryListView: View {
    let controller: CaptureController
    @State private var records: [MemoryRecord] = []
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Kayıt", value: "\(controller.memoryCount)")
                    LabeledContent("Nemotron bekleyen", value: "\(controller.pendingCount)")
                    LabeledContent("Saklama", value: "\(controller.config.retentionDays) gün")
                    if controller.pipelineStats.droppedTotal > 0 {
                        LabeledContent("Elenen", value: controller.pipelineStats.droppedSummary)
                    }
                } footer: {
                    Text("Hepsi bu telefonda: Application Support/memory. Yüzler ve plakalar bulanık; ham video yok.")
                }
                Section {
                    ForEach(records) { record in
                        NavigationLink {
                            MemoryDetailView(record: record, store: controller.store)
                        } label: {
                            MemoryRow(record: record, store: controller.store)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { records[$0].id }
                        records.remove(atOffsets: offsets)
                        Task { for id in ids { await controller.deleteMemory(id) } }
                    }
                }
            }
            .navigationTitle("Hafıza")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Son 10 dakikayı unut", systemImage: "clock.arrow.circlepath") {
                            Task { await controller.forget(minutes: 10); await reload() }
                        }
                        Button("Tümünü sil", systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Tüm hafıza silinsin mi?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Tümünü sil", role: .destructive) {
                    Task { await controller.deleteAllMemories(); await reload() }
                }
            }
            .refreshable { await reload() }
            .task(id: controller.memoryRevision) { await reload() }
        }
    }

    private func reload() async {
        records = await controller.store.recent(limit: 300)
    }
}

struct MemoryRow: View {
    let record: MemoryRecord
    let store: MemoryStore

    var body: some View {
        HStack(spacing: 12) {
            KeyframeImage(url: store.frameURL(record), maxPixel: 200)
                .frame(width: 56, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(record.seenAt.formatted(date: .abbreviated, time: .shortened) + (record.street.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let phone = record.phone {
                    Label(phone, systemImage: "phone").font(.caption)
                }
                statusLabel
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch record.status {
        case .pending: Label("Nemotron bekliyor", systemImage: "hourglass").font(.caption2).foregroundStyle(.secondary)
        case .failed: Label("Yapılandırılamadı (yalnız OCR)", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.orange)
        case .enriched: EmptyView()
        }
    }
}

struct MemoryDetailView: View {
    let record: MemoryRecord
    let store: MemoryStore

    var body: some View {
        List {
            Section {
                KeyframeImage(url: store.frameURL(record), maxPixel: 1280)
                    .frame(height: 360)
                    .listRowInsets(EdgeInsets())
            }
            Section("Kayıt") {
                row("Tür", record.kind)
                row("Ad", record.name)
                row("Telefon", record.phone)
                row("Saat", record.hours)
                row("Açıklama", record.caption)
                row("Diğer yazı", record.otherText)
                row("Anahtar kelimeler", record.keywords)
                if let c = record.confidence { LabeledContent("Güven", value: String(format: "%.2f", c)) }
            }
            Section("Karede okunan yazı (harfi harfine)") {
                Text(record.ocrText.isEmpty ? "—" : record.ocrText).font(.callout.monospaced()).textSelection(.enabled)
            }
            Section("Ne zaman, nerede") {
                LabeledContent("Zaman", value: record.seenAt.formatted(date: .complete, time: .standard))
                row("Sokak", record.street)
                if let lat = record.latitude, let lon = record.longitude {
                    let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 500, longitudinalMeters: 500))) {
                        Marker(record.title, coordinate: c)
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { LabeledContent(title, value: value) }
    }
}
