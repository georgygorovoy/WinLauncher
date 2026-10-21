import Foundation

actor XboxRuntimeManager {
    private let paths: AppPaths
    private let runner: ProcessRunner
    private let fileManager: FileManager

    init(paths: AppPaths, runner: ProcessRunner, fileManager: FileManager = .default) {
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    func installAndLaunch() async throws -> ProcessResult {
        try await run(logPrefix: "minecraft-setup")
    }

    func launch() async throws -> ProcessResult {
        try await run(logPrefix: "minecraft")
    }

    private func run(logPrefix: String) async throws -> ProcessResult {
        guard let bundle = bundledRuntime(),
              let worker = executable(bundle.appendingPathComponent("worker/BedrockWorker")) else {
            throw WinLauncherError.xboxRuntimeNotInstalled
        }
        let log = paths.logs.appendingPathComponent(
            "\(logPrefix)-\(Int(Date().timeIntervalSince1970)).log"
        )
        return try await runner.run(
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
