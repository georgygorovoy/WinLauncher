import Foundation
import XCTest
@testable import WinLab

final class EnvironmentAssignmentTests: XCTestCase {
    func testFollowingDefaultTracksAChangedDefault() {
        let firstDefault = UUID()
        let secondDefault = UUID()
        let assignment = EnvironmentAssignment.followDefault

        XCTAssertEqual(ApplicationEnvironmentPolicy(defaultEnvironmentID: firstDefault)
            .environmentID(for: assignment), firstDefault)
        XCTAssertEqual(ApplicationEnvironmentPolicy(defaultEnvironmentID: secondDefault)
            .environmentID(for: assignment), secondDefault)
    }

    func testPinnedApplicationIgnoresAChangedDefault() {
        let pinned = UUID()
        let assignment = EnvironmentAssignment.pinned(pinned)

        XCTAssertEqual(ApplicationEnvironmentPolicy(defaultEnvironmentID: UUID())
            .environmentID(for: assignment), pinned)
        XCTAssertEqual(ApplicationEnvironmentPolicy(defaultEnvironmentID: UUID())
            .environmentID(for: assignment), pinned)
    }
}
