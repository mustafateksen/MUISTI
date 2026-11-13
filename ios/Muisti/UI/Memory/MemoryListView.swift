import SwiftUI

/// What is stored on this phone: every kept frame (blurred), what was read, what Nemotron
/// made of it. Search, swipe to delete, "son 10 dakikayı unut", delete all.
struct MemoryListView: View {
    let controller: CaptureController
    @State private var records: [MemoryRecord] = []
    @State private var query = ""
    @State private var confirmDeleteAll = false
    @Environment(\.calendar) private var calendar

    private var filtered: [MemoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? records : records.filter { $0.matches(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !records.isEmpty, query.isEmpty {
                    Section {
                        MemorySummaryHeader(
                            total: controller.memoryCount,
                            pending: controller.pendingCount,
                            retentionDays: controller.config.retentionDays
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } footer: {
                        Label("Hepsi yalnızca bu telefonda. Yüzler ve plakalar bulanıklaştırılır; video saklanmaz.", systemImage: "lock.fill")
                            .padding(.top, Theme.Spacing.xs)
                    }
                }

                ForEach(MemoryDaySection.group(filtered, calendar: calendar)) { section in
                    Section(section.title(calendar: calendar)) {
                        ForEach(section.records) { record in
                            NavigationLink(value: record) {
                                MemoryRow(record: record, store: controller.store)
                            }
                            .swipeActions {
                                Button("Sil", systemImage: "trash", role: .destructive) { delete(record) }
                            }
                        }
                    }
                }
            }
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView(
                        "Henüz anı yok",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Kaydı başlattığında gördüğün tabelalar, numaralar ve saatler burada görünür.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search
                }
            }
            .searchable(text: $query, prompt: "Ad, numara, sokak, yazı…")
            .navigationTitle("Hafıza")
            .navigationDestination(for: MemoryRecord.self) { record in
                MemoryDetailView(record: record, controller: controller)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Seçenekler", systemImage: "ellipsis.circle") {
                        Button("Son 10 dakikayı unut", systemImage: "clock.arrow.circlepath", action: forgetRecent)
                        Button("Tümünü sil", systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                    }
                    .labelStyle(.iconOnly)
                    .confirmationDialog("Tüm hafıza silinsin mi?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                        Button("Tümünü sil", role: .destructive, action: deleteAll)
                    } message: {
                        Text("Bu telefondaki bütün kareler ve kayıtlar kalıcı olarak silinir.")
                    }
                }
            }
            .refreshable { await reload() }
            .task(id: controller.memoryRevision) { await reload() }
        }
    }

    private func reload() async {
        records = await controller.store.recent(limit: 300)
    }

    private func delete(_ record: MemoryRecord) {
        withAnimation { records.removeAll { $0.id == record.id } }
        Task { await controller.deleteMemory(record.id) }
    }

    private func forgetRecent() {
        Task {
            await controller.forget(minutes: 10)
            await reload()
        }
    }

    private func deleteAll() {
        Task {
            await controller.deleteAllMemories()
            await reload()
        }
    }
}
