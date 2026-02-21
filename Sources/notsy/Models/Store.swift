import Foundation
import SwiftUI

@Observable
final class NoteStore {
    var notes: [Note] = []
    var notionSyncStatusMessage: String?
    var notionSyncStatusIsError: Bool = false
    var notionSyncInFlight: Bool = false

    private let saveURL: URL
    private var syncTasks: [UUID: Task<Void, Never>] = [:]
    private var clearNotionStatusTask: Task<Void, Never>?
    private var notionSyncIndicatorDelayTask: Task<Void, Never>?
    var hasPendingNotionSync: Bool { !syncTasks.isEmpty || notionSyncInFlight }
    private var isNotionSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: NotionSyncService.enabledDefaultsKey)
    }

    init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("Notsy")
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)
        }
        self.saveURL = appSupport.appendingPathComponent("notes.json")
        self.load()
    }

    func load() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([Note].self, from: data) {
            self.notes = decoded.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func save() {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(notes) {
            try? encoded.write(to: saveURL)
        }
    }

    func insert(_ note: Note) {
        notes.insert(note, at: 0)
        save()
        scheduleNotionSync(for: note)
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        save()
        syncTasks[note.id]?.cancel()
        syncTasks.removeValue(forKey: note.id)
    }

    func togglePin(for note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index].pinned.toggle()
            // For @Observable classes, if we mutate a property of a reference type inside an array,
            // the array itself does not trigger an update. We need to replace the entire object or force a structural change.
            var newNotes = notes
            let oldNote = newNotes.remove(at: index)
            newNotes.insert(oldNote, at: index)
            notes = newNotes
            save()
            scheduleNotionSync(for: notes[index])
        }
    }

    func sortNotes() {
        let sorted = notes.sorted { $0.updatedAt > $1.updatedAt }
        notes = sorted
    }

    func saveNoteChanges(noteID: UUID? = nil) {
        let targetID = noteID ?? notes.max(by: { $0.updatedAt < $1.updatedAt })?.id
        if let targetID,
           let index = notes.firstIndex(where: { $0.id == targetID }) {
            // Force a structural array change so Observation updates list rows immediately.
            var newNotes = notes
            let sameNote = newNotes.remove(at: index)
            newNotes.insert(sameNote, at: index)
            notes = newNotes
        } else {
            notes = notes
        }
        save()

        guard let targetID,
              let note = notes.first(where: { $0.id == targetID }) else { return }
        scheduleNotionSync(for: note)
    }

    func updateTitle(noteID: UUID, title: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        let previous = notes[index].title
        if previous.isEmpty, let first = title.first {
            notes[index].title = String(first).uppercased() + title.dropFirst()
        } else {
            notes[index].title = title
        }
        notes[index].updatedAt = Date()
        saveNoteChanges(noteID: noteID)
    }

    private func scheduleNotionSync(for note: Note) {
        guard isNotionSyncEnabled else { return }

        let snapshot = NotionNoteSnapshot(
            id: note.id,
            title: note.title,
            plainText: note.plainTextCache
        )
        syncTasks[note.id]?.cancel()
        syncTasks[note.id] = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            guard isNotionSyncEnabled else { return }

            await MainActor.run {
                clearNotionStatusTask?.cancel()
                notionSyncStatusIsError = false
                notionSyncIndicatorDelayTask?.cancel()
                notionSyncIndicatorDelayTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        notionSyncInFlight = true
                        notionSyncStatusMessage = "Syncing to Notion..."
                    }
                }
            }

            let result = await NotionSyncService.shared.sync(note: snapshot)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                notionSyncIndicatorDelayTask?.cancel()
                notionSyncIndicatorDelayTask = nil
                notionSyncInFlight = false
                syncTasks.removeValue(forKey: note.id)

                switch result {
                case .synced:
                    notionSyncStatusIsError = false
                    notionSyncStatusMessage = "Saved to Notion."
                    clearNotionStatusTask?.cancel()
                    clearNotionStatusTask = Task {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            notionSyncStatusMessage = nil
                        }
                    }
                case .skipped:
                    notionSyncStatusIsError = false
                    notionSyncStatusMessage = nil
                case .failed(let message):
                    notionSyncStatusIsError = true
                    notionSyncStatusMessage = "Notion sync failed: \(message)"
                }
            }
        }
    }

    func cancelPendingNotionSync() {
        for task in syncTasks.values {
            task.cancel()
        }
        syncTasks.removeAll()
        clearNotionStatusTask?.cancel()
        notionSyncIndicatorDelayTask?.cancel()
        notionSyncInFlight = false
        notionSyncStatusIsError = false
        notionSyncStatusMessage = nil
    }

    func flushPendingNotionSync(timeoutNanoseconds: UInt64 = 6_000_000_000) async -> Bool {
        let tasksToWait = syncTasks.values.map { $0 }
        guard !tasksToWait.isEmpty else { return true }

        await MainActor.run {
            clearNotionStatusTask?.cancel()
            notionSyncInFlight = true
            notionSyncStatusIsError = false
            notionSyncStatusMessage = "Finalizing Notion sync before quit..."
        }

        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for task in tasksToWait {
                    _ = await task.result
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        await MainActor.run {
            notionSyncInFlight = false
            if completed {
                notionSyncStatusIsError = false
                notionSyncStatusMessage = "Saved to Notion."
            } else {
                notionSyncStatusIsError = true
                notionSyncStatusMessage = "Quit before Notion sync finished."
            }
        }

        return completed
    }
}
