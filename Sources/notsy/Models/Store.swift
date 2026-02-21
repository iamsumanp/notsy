import Foundation
import SwiftUI

@Observable
final class NoteStore {
    var notes: [Note] = []

    private let saveURL: URL
    private var syncTasks: [UUID: Task<Void, Never>] = [:]

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
        // Trigger SwiftUI update explicitly without sorting!
        // Sorting while actively typing causes indices to shift and overwrites the wrong file.
        let newNotes = notes
        notes = newNotes
        save()

        let targetID = noteID ?? notes.max(by: { $0.updatedAt < $1.updatedAt })?.id
        guard let targetID,
              let note = notes.first(where: { $0.id == targetID }) else { return }
        scheduleNotionSync(for: note)
    }

    private func scheduleNotionSync(for note: Note) {
        let snapshot = NotionNoteSnapshot(
            id: note.id,
            title: note.title,
            plainText: note.plainTextCache
        )
        syncTasks[note.id]?.cancel()
        syncTasks[note.id] = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await NotionSyncService.shared.sync(note: snapshot)
        }
    }
}
