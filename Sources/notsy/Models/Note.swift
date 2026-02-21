import Foundation

class Note: Identifiable, Codable, Equatable, Hashable {
    static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id
    }
    
    // Conforming to Hashable explicitly helps SwiftUI ForEach and LazyVStack track identity
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var id: UUID
    var title: String = ""
    var attributedContent: Data
    var plainTextCache: String
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool

    init(
        id: UUID = UUID(),
        title: String = "",
        attributedContent: Data = Data(),
        plainTextCache: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        pinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.attributedContent = attributedContent
        self.plainTextCache = plainTextCache
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinned = pinned
    }

    var stringRepresentation: NSAttributedString {
        guard !attributedContent.isEmpty else { return NSAttributedString(string: plainTextCache) }
        // Prefer RTFD for embedded media (images), with RTF fallback for older notes.
        let rtfdOptions: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtfd
        ]
        if let attrStr = try? NSAttributedString(data: attributedContent, options: rtfdOptions, documentAttributes: nil) {
            return attrStr
        }

        let rtfOptions: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        if let attrStr = try? NSAttributedString(data: attributedContent, options: rtfOptions, documentAttributes: nil) {
            return attrStr
        }
        return NSAttributedString(string: plainTextCache)
    }

    func update(with attributedString: NSAttributedString) {
        let range = NSRange(location: 0, length: attributedString.length)
        let rtfdOptions: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtfd
        ]
        if let rtfdData = try? attributedString.data(from: range, documentAttributes: rtfdOptions) {
            self.attributedContent = rtfdData
        } else {
            let rtfOptions: [NSAttributedString.DocumentAttributeKey: Any] = [
                .documentType: NSAttributedString.DocumentType.rtf
            ]
            if let rtfData = try? attributedString.data(from: range, documentAttributes: rtfOptions) {
                self.attributedContent = rtfData
            }
        }
        self.plainTextCache = attributedString.string
        self.updatedAt = Date()
    }
}
