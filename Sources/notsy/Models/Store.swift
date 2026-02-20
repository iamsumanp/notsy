import Foundation
import SwiftUI

@Observable
final class NoteStore {
    var notes: [Note] = []

    private let saveURL: URL

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
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        save()
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
        }
    }

    func sortNotes() {
        let sorted = notes.sorted { $0.updatedAt > $1.updatedAt }
        notes = sorted
    }

    func saveNoteChanges() {
        // Trigger SwiftUI update explicitly without sorting!
        // Sorting while actively typing causes indices to shift and overwrites the wrong file.
        var newNotes = notes
        notes = newNotes
        save()
    }
}
