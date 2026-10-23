import Foundation

struct XboxRuntimeProgress: Decodable, Sendable {
    let state: String
    let title: String
    let detail: String
    let progress: Double?
}

actor XboxRuntimeManager {
    private let paths: AppPaths
    private let runner: ProcessRunner
    private let fileManager: FileManager

    init(paths: AppPaths, runner: ProcessRunner, fileManager: FileManager = .default) {
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    func installAndLaunch(
        progress: (@Sendable (XboxRuntimeProgress) async -> Void)? = nil
    ) async throws -> ProcessResult {
        try await run(logPrefix: "minecraft-setup", progress: progress)
    }

    func launch(
        progress: (@Sendable (XboxRuntimeProgress) async -> Void)? = nil
    ) async throws -> ProcessResult {
        try await run(logPrefix: "minecraft", progress: progress)
    }

    private func run(
        logPrefix: String,
        progress: (@Sendable (XboxRuntimeProgress) async -> Void)?
    ) async throws -> ProcessResult {
        guard let bundle = bundledRuntime(),
              let worker = executable(bundle.appendingPathComponent("worker/BedrockWorker")) else {
            throw WinLauncherError.xboxRuntimeNotInstalled
        }
        let log = paths.logs.appendingPathComponent(
            "\(logPrefix)-\(Int(Date().timeIntervalSince1970)).log"
        )
        let monitor = Task {
            var offset = 0
            var pending = Data()
            while !Task.isCancelled {
                (offset, pending) = await Self.publishProgress(
                    from: log,
                    after: offset,
                    pending: pending,
                    handler: progress
                )
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        do {
            let result = try await runner.run(
                executable: worker,
                arguments: [],
                environment: [
                    "HOME": fileManager.homeDirectoryForCurrentUser.path,
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "BEDROCK_BUNDLE": bundle.path,
                    "BEDROCK_HOME": paths.xboxSupport.path,
                    "XODUS_LOG": "off",
                    "RUST_LOG": "off"
                ],
                logURL: log
            )
            monitor.cancel()
            _ = await monitor.result
            return result
        } catch {
            monitor.cancel()
            _ = await monitor.result
            throw error
        }
    }

    private static func publishProgress(
        from log: URL,
        after offset: Int,
        pending: Data,
        handler: (@Sendable (XboxRuntimeProgress) async -> Void)?
    ) async -> (Int, Data) {
        guard let handler,
              let contents = try? Data(contentsOf: log),
              contents.count >= offset else { return (offset, pending) }
        var buffer = pending
        buffer.append(contents.suffix(from: offset))
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            if let update = try? JSONDecoder().decode(XboxRuntimeProgress.self, from: Data(line)) {
                await handler(update)
            }
            start = buffer.index(after: newline)
        }
        return (contents.count, Data(buffer[start...]))
    }

    private func bundledRuntime() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let bundle = resources.appendingPathComponent("XboxRuntime", isDirectory: true)
        let wine = bundle.appendingPathComponent("runtime/wine/bin/wine")
        let dxmt = bundle.appendingPathComponent("runtime/dxmt/x86_64-windows/d3d11.dll")
        let helper = bundle.appendingPathComponent("standalone_helper")
        guard executable(wine) != nil,
              fileManager.fileExists(atPath: dxmt.path),
              executable(helper) != nil else { return nil }
        return bundle
    }

    private func executable(_ url: URL) -> URL? {
        fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }
}
