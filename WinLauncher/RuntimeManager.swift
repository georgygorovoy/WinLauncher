import CryptoKit
import Foundation

actor RuntimeManager {
    private static let monoVersion = "11.3.0"
    private static let monoFileName = "wine-mono-11.3.0-x86.msi"
    private static let monoURL = URL(string: "https://dl.winehq.org/wine/wine-mono/11.3.0/wine-mono-11.3.0-x86.msi")!
    private static let monoSHA256 = "df2dfc1665c2511882e7cabd56eafd0c0a3d94e5a7e86f969277f6c189d418d3"

    private let paths: AppPaths
    private let runner: ProcessRunner
    private let prefixManager: PrefixManager

    init(paths: AppPaths, runner: ProcessRunner, prefixManager: PrefixManager) {
        self.paths = paths
        self.runner = runner
        self.prefixManager = prefixManager
    }

    func ensureMono(engine: WineEngineInstallation) async throws {
        let marker = paths.prefix.appendingPathComponent(".winlauncher-mono-\(Self.monoVersion)")
        let runtime = paths.prefix.appendingPathComponent("drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86.dll")
        if FileManager.default.fileExists(atPath: runtime.path) {
            if !FileManager.default.fileExists(atPath: marker.path) {
                try Data(Self.monoVersion.utf8).write(to: marker, options: .atomic)
            }
            return
        }

        try paths.createBaseDirectories()
        let cached = paths.dependencies.appendingPathComponent(Self.monoFileName)
        if !valid(cached) {
            try? FileManager.default.removeItem(at: cached)
            let (temporary, response) = try await URLSession.shared.download(from: Self.monoURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw WinLauncherError.engineDownloadFailed("Wine Mono download returned an invalid response.")
            }
            guard valid(temporary) else { throw WinLauncherError.engineIntegrityFailed }
            try FileManager.default.copyItem(at: temporary, to: cached)
        }

        let support = paths.prefix.appendingPathComponent("drive_c/users/Public/WinLauncherSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let installer = support.appendingPathComponent(Self.monoFileName)
        try? FileManager.default.removeItem(at: installer)
        try FileManager.default.copyItem(at: cached, to: installer)
        defer { try? FileManager.default.removeItem(at: installer) }

        let log = paths.logs.appendingPathComponent("runtime-mono-\(Self.monoVersion).log")
        let result = try await runner.run(
            executable: engine.wineURL,
            arguments: ["msiexec", "/i", "C:\\users\\Public\\WinLauncherSupport\\\(Self.monoFileName)", "/qn", "/norestart"],
            environment: await prefixManager.wineEnvironment(engine: engine),
            logURL: log
        )
        guard result.terminationStatus == 0,
              FileManager.default.fileExists(atPath: runtime.path) else {
            throw WinLauncherError.processFailed(".NET support installation", result.terminationStatus, result.logURL)
        }
        try Data(Self.monoVersion.utf8).write(to: marker, options: .atomic)
    }

    private func valid(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == Self.monoSHA256
    }
}
