import Foundation

struct EnvironmentConfiguration: Codable, Equatable {
    let schemaVersion: Int
    let createdAt: Date
    let engine: WineEngine
    let productPolicy: String
    let confinementNotice: String
}

struct RunManifest: Codable, Equatable {
    let schemaVersion: Int
    let id: UUID
    let startedAt: Date
    let operation: String
    let engine: WineEngine
    let environmentPath: String
    let executablePath: String
    let arguments: [String]
    let environmentOverrides: [String: String]
    let host: HostInformation
    var finishedAt: Date?
    var exitStatus: Int32?
}

struct HostInformation: Codable, Equatable {
    let operatingSystem: String
    let architecture: String

    static var current: HostInformation {
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return HostInformation(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                               architecture: machine)
    }
}

enum JSONFiles {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
