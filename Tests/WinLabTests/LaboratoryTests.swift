import Foundation
import XCTest
@testable import WinLab

final class LaboratoryTests: XCTestCase {
    func testOverrideParsingAndRedaction() throws {
        let values = try Laboratory.parseOverrides(["DXMT_LOG_LEVEL=debug", "ACCESS_TOKEN=private"])
        XCTAssertEqual(values["DXMT_LOG_LEVEL"], "debug")
        XCTAssertEqual(Laboratory.redacted(values)["ACCESS_TOKEN"], "<redacted>")
    }

    func testInvalidOverrideNameIsRejected() {
        XCTAssertThrowsError(try Laboratory.parseOverrides(["BAD-NAME=value"]))
        XCTAssertThrowsError(try Laboratory.parseOverrides(["WINEPREFIX=/tmp/escape"]))
        XCTAssertThrowsError(try Laboratory.parseOverrides(["DYLD_INSERT_LIBRARIES=/tmp/code.dylib"]))
    }

    func testBroadEnvironmentPathsAreRejected() {
        XCTAssertThrowsError(try LabPaths(root: URL(fileURLWithPath: "/")))
        XCTAssertThrowsError(try LabPaths(root: FileManager.default.homeDirectoryForCurrentUser))
    }
}
