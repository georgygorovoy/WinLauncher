import Foundation

struct Laboratory {
    private let runner: ProcessRunning
    private let fileManager: FileManager
    private let now: () -> Date

    init(runner: ProcessRunning = ProcessRunner(), fileManager: FileManager = .default,
         now: @escaping () -> Date = Date.init) {
        self.runner = runner
        self.fileManager = fileManager
        self.now = now
    }

    func doctor(enginePath: String) throws -> WineEngine {
        try WineEngine.resolve(path: enginePath, runner: runner)
    }

    func initialize(enginePath: String, environmentPath: String) throws -> EnvironmentConfiguration {
        let engine = try doctor(enginePath: enginePath)
        let paths = try LabPaths(root: URL(fileURLWithPath: environmentPath), fileManager: fileManager)
        guard !fileManager.fileExists(atPath: paths.configuration.path) else {
            throw CLIError.usage("Environment is already initialized: \(paths.root.path)")
        }
        try paths.create(fileManager: fileManager)
        let configuration = EnvironmentConfiguration(
            schemaVersion: 1,
            createdAt: now(),
            engine: engine,
            productPolicy: "One shared Windows Environment is the product default.",
            confinementNotice: "This Wine prefix is test isolation, not an operating-system security sandbox."
        )
        let logURL = paths.logs.appending(path: "initialize.log")
        let status = try runner.run(executable: URL(fileURLWithPath: engine.executablePath),
                                    arguments: ["wineboot", "--init"],
                                    environment: processEnvironment(prefix: paths.prefix, overrides: [:], initialize: true),
                                    logURL: logURL)
        guard status == 0 else {
            throw CLIError.processFailed(executable: engine.executablePath, status: status, log: logURL)
        }
        try JSONFiles.write(configuration, to: paths.configuration)
        return configuration
    }

    func run(operation: String, enginePath: String, environmentPath: String,
             executablePath: String, arguments: [String], overrides: [String]) throws -> RunManifest {
        let engine = try doctor(enginePath: enginePath)
        let paths = try LabPaths(root: URL(fileURLWithPath: environmentPath), fileManager: fileManager)
        guard fileManager.fileExists(atPath: paths.configuration.path),
              fileManager.fileExists(atPath: paths.prefix.path) else {
            throw CLIError.missingFile("Environment is not initialized: \(paths.root.path)")
        }
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL.resolvingSymlinksInPath()
        let executableValues = try? executable.resourceValues(forKeys: [.isRegularFileKey])
        guard executableValues?.isRegularFile == true, fileManager.isReadableFile(atPath: executable.path) else {
            throw CLIError.missingFile("Executable is not readable: \(executable.path)")
        }
        let parsedOverrides = try Self.parseOverrides(overrides)
        let id = UUID()
        let manifestURL = paths.manifests.appending(path: "\(id.uuidString).json")
        let logURL = paths.logs.appending(path: "\(id.uuidString).log")
        var manifest = RunManifest(schemaVersion: 1, id: id, startedAt: now(), operation: operation,
                                   engine: engine, environmentPath: paths.root.path,
                                   executablePath: executable.path, arguments: arguments,
                                   environmentOverrides: Self.redacted(parsedOverrides), host: .current,
                                   finishedAt: nil, exitStatus: nil)
        try JSONFiles.write(manifest, to: manifestURL)
        let status = try runner.run(executable: URL(fileURLWithPath: engine.executablePath),
                                    arguments: [executable.path] + arguments,
                                    environment: processEnvironment(prefix: paths.prefix,
                                                                    overrides: parsedOverrides,
                                                                    initialize: false),
                                    logURL: logURL)
        manifest.finishedAt = now()
        manifest.exitStatus = status
        try JSONFiles.write(manifest, to: manifestURL)
        guard status == 0 else {
            throw CLIError.processFailed(executable: executable.path, status: status, log: logURL)
        }
        return manifest
    }

    static func parseOverrides(_ values: [String]) throws -> [String: String] {
        let reserved = ["HOME", "PATH", "WINEPREFIX", "WINEARCH"]
        return try values.reduce(into: [:]) { result, item in
            guard let separator = item.firstIndex(of: "="), separator != item.startIndex else {
                throw CLIError.usage("Environment override must use KEY=VALUE: \(item)")
            }
            let key = String(item[..<separator])
            guard key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                throw CLIError.usage("Invalid environment variable name: \(key)")
            }
            guard !reserved.contains(key.uppercased()), !key.uppercased().hasPrefix("DYLD_") else {
                throw CLIError.usage("The laboratory controls reserved environment variable: \(key)")
            }
            result[key] = String(item[item.index(after: separator)...])
        }
    }

    static func redacted(_ values: [String: String]) -> [String: String] {
        let sensitiveFragments = ["TOKEN", "PASSWORD", "SECRET", "COOKIE", "KEY"]
        return values.mapValues { $0 }.reduce(into: [:]) { result, pair in
            result[pair.key] = sensitiveFragments.contains(where: { pair.key.uppercased().contains($0) })
                ? "<redacted>" : pair.value
        }
    }

    private func processEnvironment(prefix: URL, overrides: [String: String], initialize: Bool) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides { environment[key] = value }
        environment["WINEPREFIX"] = prefix.path
        environment["WINEDEBUG"] = environment["WINEDEBUG"] ?? "-all"
        if initialize { environment["WINEARCH"] = "wow64" }
        return environment
    }
}
