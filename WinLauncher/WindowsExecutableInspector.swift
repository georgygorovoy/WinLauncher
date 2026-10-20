import Foundation

enum WindowsExecutableInspector {
    private static let windowsRuntimeReferences = [
        "Windows.Foundation.UniversalApiContract",
        "Windows.ApplicationModel.Store",
        "Microsoft.WindowsAppRuntime"
    ]

    static func isManaged(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 0x40,
              header[0] == 0x4d, header[1] == 0x5a else { return false }
        let peOffset = Int(readUInt32(header, at: 0x3c))
        guard peOffset >= 0, peOffset + 24 <= header.count,
              header[peOffset] == 0x50, header[peOffset + 1] == 0x45 else { return false }
        let optionalHeader = peOffset + 24
        let magic = readUInt16(header, at: optionalHeader)
        let dataDirectory: Int
        switch magic {
        case 0x10b: dataDirectory = optionalHeader + 96
        case 0x20b: dataDirectory = optionalHeader + 112
        default: return false
        }
        let cliHeader = dataDirectory + (14 * 8)
        guard cliHeader + 8 <= header.count else { return false }
        return readUInt32(header, at: cliHeader) != 0 && readUInt32(header, at: cliHeader + 4) != 0
    }

    static func requiresWindowsRuntime(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return windowsRuntimeReferences.contains { reference in
            guard let bytes = reference.data(using: .utf8) else { return false }
            return data.range(of: bytes) != nil
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
