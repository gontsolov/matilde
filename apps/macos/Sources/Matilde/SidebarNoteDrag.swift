import Foundation
import UniformTypeIdentifiers
import MatildeKit

/// A sidebar note being dragged to another folder. The pasteboard carries only
/// a private type, so dropping it on the editor or Finder never inserts text.
struct SidebarNoteDrag: Equatable {
    static let typeIdentifier = "app.matilde.local.note"
    /// Declared in the bundle's Info.plist by scripts/write-info.py.
    static let type = UTType(exportedAs: typeIdentifier, conformingTo: .data)
    var family: String
    var folder: String

    static func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data(typeIdentifier.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .all) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }
    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        !providers.isEmpty && providers.allSatisfy { $0.registeredTypeIdentifiers.contains(typeIdentifier) }
    }
}
