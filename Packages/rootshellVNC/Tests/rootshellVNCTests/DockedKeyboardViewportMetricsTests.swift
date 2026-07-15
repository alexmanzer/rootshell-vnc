import CoreGraphics
import XCTest
@testable import rootshellVNC

final class DockedKeyboardViewportMetricsTests: XCTestCase {
    func testStaleInsetIsIgnoredAfterKeyboardRequestEnds() {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: CGSize(width: 390, height: 844),
            keyboardInset: 291)

        XCTAssertEqual(
            metrics.effectiveInset(reservingObstruction: false),
            0)
        XCTAssertEqual(
            metrics.availableSize(reservingObstruction: false),
            CGSize(width: 390, height: 844))
    }

    func testInsetIsReservedWhileKeyboardIsRequested() {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: CGSize(width: 390, height: 844),
            keyboardInset: 291)

        XCTAssertEqual(
            metrics.effectiveInset(reservingObstruction: true),
            291)
        XCTAssertEqual(
            metrics.availableSize(reservingObstruction: true),
            CGSize(width: 390, height: 553))
    }

    func testInsetCannotProduceNegativeViewportHeight() {
        let metrics = DockedKeyboardViewportMetrics(
            containerSize: CGSize(width: 390, height: 200),
            keyboardInset: 291)

        XCTAssertEqual(
            metrics.availableSize(reservingObstruction: true).height,
            0)
    }
}
