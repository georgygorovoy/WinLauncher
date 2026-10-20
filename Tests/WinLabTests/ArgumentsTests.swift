import XCTest
@testable import WinLab

final class ArgumentsTests: XCTestCase {
    func testRepeatedArgumentsRemainOrdered() throws {
        let parsed = try ParsedArguments(["run", "--engine", "/Wine", "--arg", "first", "--arg", "second"])
        XCTAssertEqual(parsed.command, "run")
        XCTAssertEqual(parsed.all("arg"), ["first", "second"])
        XCTAssertEqual(try parsed.required("engine"), "/Wine")
    }

    func testRejectsMissingOptionValue() {
        XCTAssertThrowsError(try ParsedArguments(["run", "--engine"]))
    }
}
