import Foundation

struct LabPaths {
    let root: URL

    var prefix: URL { root.appending(path: "prefix", directoryHint: .isDirectory) }
    var logs: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
    var manifests: URL { root.appending(path: "manifests", directoryHint: .isDirectory) }
    var configuration: URL { root.appending(path: "environment.json") }

    init(root: URL, fileManager: FileManager = .default) throws {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path != "/", resolved.path != home.path else {
            throw CLIError.unsafeEnvironmentPath("Refusing to use a filesystem root or home directory as the laboratory environment.")
        }
        guard resolved.pathComponents.count >= 4 else {
            throw CLIError.unsafeEnvironmentPath("Environment path is too broad: \(resolved.path)")
        }
        self.root = resolved
    }

    func create(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        for directory in [prefix, logs, manifests] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
    }
}
