import Foundation

struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let output: String
    let logURL: URL
}

actor ProcessRunner {
    func run(executable: URL, arguments: [String], environment: [String: String],
             logURL: URL) async throws -> ProcessResult {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let prefix = environment["WINEPREFIX"] {
            let windowsDrive = URL(fileURLWithPath: prefix, isDirectory: true)
                .appendingPathComponent("drive_c", isDirectory: true)
            if FileManager.default.fileExists(atPath: windowsDrive.path) {
                process.currentDirectoryURL = windowsDrive
            }
        }
        process.standardOutput = handle
        process.standardError = handle

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    try? handle.close()
                    let data = (try? Data(contentsOf: logURL)) ?? Data()
                    let output = String(decoding: data.suffix(128_000), as: UTF8.self)
                    continuation.resume(returning: ProcessResult(
                        terminationStatus: finished.terminationStatus,
                        output: output,
                        logURL: logURL
                    ))
                }
                do { try process.run() }
                catch {
                    try? handle.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
