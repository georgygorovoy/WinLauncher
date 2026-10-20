import Foundation

struct CapturedProcessResult: Equatable {
    let status: Int32
    let output: String
}

protocol ProcessRunning {
    func capture(executable: URL, arguments: [String], environment: [String: String]?) throws -> CapturedProcessResult
    func run(executable: URL, arguments: [String], environment: [String: String], logURL: URL) throws -> Int32
}

struct ProcessRunner: ProcessRunning {
    func capture(executable: URL, arguments: [String], environment: [String: String]?) throws -> CapturedProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CapturedProcessResult(status: process.terminationStatus,
                                     output: String(decoding: data, as: UTF8.self))
    }

    func run(executable: URL, arguments: [String], environment: [String: String], logURL: URL) throws -> Int32 {
        FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
