import Foundation

struct WineEngine: Codable, Equatable {
    let requestedPath: String
    let executablePath: String
    let version: String

    static func resolve(path: String, runner: ProcessRunning = ProcessRunner()) throws -> WineEngine {
        let requested = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let candidates = [
            requested,
            requested.appending(path: "bin/wine"),
            requested.appending(path: "Contents/Resources/wine/bin/wine"),
            requested.appending(path: "Contents/Resources/wine/bin/wine64"),
            requested.appending(path: "Contents/Resources/bin/wine"),
        ]
        guard let executable = candidates.first(where: {
            let values = try? $0.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true && FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CLIError.missingFile("No executable Wine loader found under \(requested.path)")
        }
        let result = try runner.capture(executable: executable, arguments: ["--version"], environment: nil)
        guard result.status == 0 else {
            throw CLIError.processFailed(executable: executable.path, status: result.status, log: nil)
        }
        let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw CLIError.invalidPath("Wine returned an empty version string.") }
        return WineEngine(requestedPath: requested.path, executablePath: executable.path, version: version)
    }
}
