import Darwin
import CryptoKit
import Foundation

struct XboxSupportStatus: Sendable {
    let helperAvailable: Bool
    let gamePrepared: Bool
    let runtimeAvailable: Bool

    var description: String {
        if gamePrepared && runtimeAvailable { return "Ready to play" }
        if gamePrepared { return "Game downloaded · Player runtime required" }
        if helperAvailable { return "Microsoft account helper is ready" }
        return "Account helper is not installed"
    }
}

/// Adapter for the separately distributed GPL account/download helper.
/// The helper is never linked into WinLauncher and receives no Wine environment.
actor XboxHelperManager {
    private static let approvedHelperSHA256 = "cce9d9cc3cf72b9acf03eaae413be6f16bf838c1141ffcfa9ab182e416580ff4"
    private let paths: AppPaths
    private let runner: ProcessRunner
    private let fileManager: FileManager

    init(paths: AppPaths, runner: ProcessRunner, fileManager: FileManager = .default) {
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    func status() -> XboxSupportStatus {
        migrateLegacyGameIfNeeded()
        return XboxSupportStatus(
            helperAvailable: validatedHelper() != nil,
            gamePrepared: isPreparedGame(at: paths.minecraftGame),
            runtimeAvailable: isPlayerRuntimeAvailable()
        )
    }

    func installBundledHelperIfAvailable() throws -> Bool {
        guard validatedHelper() == nil,
              let bundled = Bundle.main.url(forResource: "standalone_helper", withExtension: nil,
                                            subdirectory: "XboxHelper") else {
            return validatedHelper() != nil
        }
        try fileManager.createDirectory(at: paths.xboxHelper.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let temporary = paths.xboxHelper.deletingLastPathComponent()
            .appendingPathComponent(".standalone_helper-\(UUID().uuidString)")
        try fileManager.copyItem(at: bundled, to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: paths.xboxHelper.path) {
            try fileManager.removeItem(at: temporary)
            return validatedHelper() != nil
        }
        try fileManager.moveItem(at: temporary, to: paths.xboxHelper)
        return validatedHelper() != nil
    }

    func downloadOwnedMinecraft(market: String) async throws -> URL {
        migrateLegacyGameIfNeeded()
        guard let helper = validatedHelper() else { throw WinLauncherError.xboxHelperNotInstalled }
        guard market.count == 2, market.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw WinLauncherError.xboxHelperInvalid
        }
        if isPreparedGame(at: paths.minecraftGame) { return paths.minecraftGame }
        guard !fileManager.fileExists(atPath: paths.minecraftGame.path) else {
            throw WinLauncherError.xboxHelperInvalid
        }
        let log = paths.logs.appendingPathComponent("xbox-setup-\(Int(Date().timeIntervalSince1970)).log")
        let result = try await runner.run(
            executable: helper,
            arguments: ["--download", paths.minecraftGame.path, "--market", market.uppercased()],
            environment: [
                "HOME": fileManager.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "XODUS_LOG": "off",
                "RUST_LOG": "off"
            ],
            logURL: log
        )
        guard result.terminationStatus == 0, isPreparedGame(at: paths.minecraftGame) else {
            throw WinLauncherError.xboxGameDownloadFailed(log)
        }
        return paths.minecraftGame
    }

    private func validatedHelper() -> URL? {
        let candidates = [
            Bundle.main.url(forResource: "standalone_helper", withExtension: nil,
                            subdirectory: "XboxHelper"),
            paths.xboxHelper
        ].compactMap { $0 }
        return candidates.first { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && fileManager.isExecutableFile(atPath: url.path)
                && !url.pathExtension.lowercased().contains("app"),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
                  permissions & 0o022 == 0 else { return false }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return digest == Self.approvedHelperSHA256
        }
    }

    private func isPreparedGame(at directory: URL) -> Bool {
        let executable = directory.appendingPathComponent("Minecraft.Windows.exe")
        let config = directory.appendingPathComponent("MicrosoftGame.Config")
        let metadata = directory.appendingPathComponent(".xodus-streaming.msixvc")
        guard let values = try? executable.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 1_000_000 else { return false }
        return fileManager.fileExists(atPath: config.path)
            && fileManager.fileExists(atPath: metadata.path)
    }

    private func isPlayerRuntimeAvailable() -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let bundled = resources.appendingPathComponent("XboxRuntime", isDirectory: true)
        let candidates = [
            bundled.appendingPathComponent("runtime/wine/bin/wine64"),
            bundled.appendingPathComponent("runtime/wine/bin/wine")
        ]
        let worker = bundled.appendingPathComponent("worker/BedrockWorker")
        return fileManager.isExecutableFile(atPath: worker.path)
            && candidates.contains { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func migrateLegacyGameIfNeeded() {
        guard !fileManager.fileExists(atPath: paths.minecraftGame.path),
              isPreparedGame(at: paths.legacyMinecraftGame) else { return }
        try? fileManager.moveItem(at: paths.legacyMinecraftGame, to: paths.minecraftGame)
    }
}
