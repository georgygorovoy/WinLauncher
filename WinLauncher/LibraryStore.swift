import Foundation

actor LibraryStore {
    private let paths: AppPaths
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(paths: AppPaths) {
        self.paths = paths
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> [LibraryApplication] {
        guard FileManager.default.fileExists(atPath: paths.libraryFile.path) else { return [] }
        let data = try Data(contentsOf: paths.libraryFile)
        return try decoder.decode(LibraryDocument.self, from: data).applications
    }

    func save(_ applications: [LibraryApplication]) throws {
        try paths.createBaseDirectories()
        let data = try encoder.encode(LibraryDocument(applications: applications))
        let temporary = paths.libraryFile.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: paths.libraryFile.path) {
            _ = try FileManager.default.replaceItemAt(paths.libraryFile, withItemAt: temporary,
                                                        backupItemName: nil, options: [])
        } else {
            try FileManager.default.moveItem(at: temporary, to: paths.libraryFile)
        }
    }
}
