import XCTest
@testable import Wisper

final class NotchPresentationTests: XCTestCase {
    func testPrefersNotchOnlyWhenTopSafeAreaInsetIsPositive() {
        XCTAssertTrue(OverlayWindowController.prefersNotch(topSafeAreaInset: 32))
        XCTAssertFalse(OverlayWindowController.prefersNotch(topSafeAreaInset: 0))
        XCTAssertFalse(OverlayWindowController.prefersNotch(topSafeAreaInset: -1))
    }

    func testCollapsedAndExpandedGeometryMatchDesignSpec() {
        XCTAssertEqual(NotchWindowController.Layout.collapsedSize, CGSize(width: 430, height: 40))
        XCTAssertEqual(NotchWindowController.Layout.expandedSize, CGSize(width: 580, height: 220))
    }

    func testBarHeightsMapAnyLevelCountOntoRequestedBarCountWithoutCrashing() {
        XCTAssertEqual(NotchWaveform.barHeights(from: [], barCount: 22, maxHeight: 30).count, 22)
        XCTAssertEqual(NotchWaveform.barHeights(from: [0.5], barCount: 22, maxHeight: 30).count, 22)
        XCTAssertEqual(NotchWaveform.barHeights(from: Array(repeating: CGFloat(0.4), count: 12), barCount: 22, maxHeight: 30).count, 22)
        XCTAssertEqual(NotchWaveform.barHeights(from: Array(repeating: CGFloat(0.4), count: 12), barCount: 5, maxHeight: 14).count, 5)

        let heights = NotchWaveform.barHeights(from: [1, 1, 1], barCount: 5, maxHeight: 30)
        XCTAssertTrue(heights.allSatisfy { $0 <= 30 && $0 >= 2 })
    }
}
