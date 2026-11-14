import SwiftUI

/// What is stored on this phone, as memory episodes (folders: one walk or visit each, grouped
/// by time and place). Searching shows matching frames directly. Swipe to delete,
/// "forget the last 10 minutes", delete all.
struct MemoryListView: View {
    let controller: CaptureController
    @State private var records: [MemoryRecord] = []
    @State private var episodes: [MemoryEpisode] = []
    @State private var query = ""
    @State private var confirmDeleteAll = false
    @Environment(\.calendar) private var calendar

    private var filtered: [MemoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? records : records.filter { $0.matches(trimmed) }
    }

    private var summary: MemorySummary {
        MemorySummary(
            total: controller.memoryCount,
            pending: controller.pendingCount,
            retentionDays: controller.config.retentionDays,
            visible: !records.isEmpty && query.isEmpty
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if #unavailable(iOS 26), !records.isEmpty, query.isEmpty {
                    MemorySummaryRow(summary: summary)
                }

                if query.isEmpty {
                    ForEach(MemoryDaySection.groupEpisodes(episodes, calendar: calendar), id: \.day) { section in
                        Section(MemoryDaySection.title(section.day, calendar: calendar)) {
                            ForEach(section.episodes) { episode in
                                NavigationLink(value: episode) {
                                    EpisodeRow(episode: episode, store: controller.store)
                                }
                                .accessibilityIdentifier("episodeRow")
                            }
                        }
                    }
                } else {
                    ForEach(MemoryDaySection.group(filtered, calendar: calendar)) { section in
                        Section(section.title(calendar: calendar)) {
                            ForEach(section.records) { record in
                                NavigationLink(value: record) {
                                    MemoryRow(record: record, store: controller.store)
                                }
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) { delete(record) }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No memories yet",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("When you start recording, the signs, numbers and opening hours you see will appear here.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search
                }
            }
            .searchable(text: $query, prompt: "Name, number, street, text…")
            .navigationTitle("Memory")
            .memorySummary(total: summary.total, pending: summary.pending, retentionDays: summary.retentionDays, visible: summary.visible)
            .navigationDestination(for: MemoryRecord.self) { record in
                MemoryDetailView(record: record, controller: controller)
            }
            .navigationDestination(for: MemoryEpisode.self) { episode in
                EpisodeDetailView(episode: episode, controller: controller)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Options", systemImage: "ellipsis.circle") {
                        Button("Forget the last 10 minutes", systemImage: "clock.arrow.circlepath", action: forgetRecent)
                        Button("Delete all", systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                    }
                    .labelStyle(.iconOnly)
                    .confirmationDialog("Delete all memories?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                        Button("Delete all", role: .destructive, action: deleteAll)
                    } message: {
                        Text("All frames and memories on this iPhone will be permanently deleted.")
                    }
                }
            }
            .refreshable { await reload() }
            .task(id: controller.memoryRevision) { await reload() }
        }
    }

    private func reload() async {
        records = await controller.store.recent(limit: 300)
        episodes = await controller.store.episodes(limit: 200)
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
