//  MarkdownLargeContentTests.swift
//  HermesMobileTests
//
//  Slice 0 registration skeleton for issue #17 (large Markdown content).
//  This file is registered in the test target before any #17 test command
//  runs (binding brief §8). It holds one trivial compile-safe test only;
//  the #17 RED cases are added by later slices and must not reference
//  production symbols before those symbols exist.

import XCTest

final class MarkdownLargeContentTests: XCTestCase {
    func testRegistrationSkeletonCompiles() {
        XCTAssertEqual("markdown".uppercased(), "MARKDOWN")
    }
}
