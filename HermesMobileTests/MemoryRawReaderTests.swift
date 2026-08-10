//  MemoryRawReaderTests.swift
//  HermesMobileTests
//
//  Slice 0 registration skeleton for issue #19 (secure byte-faithful raw
//  Memory source reader). This file is registered in the test target before
//  any #19 test command runs (binding contract v6 §19). It holds one trivial
//  compile-safe test only; the full #19 RED cases (parked on issue/19-reader)
//  are applied by a later slice and must not reference production symbols
//  before those symbols exist.

import XCTest

final class MemoryRawReaderTests: XCTestCase {
    func testRegistrationSkeletonCompiles() {
        XCTAssertEqual("memory".uppercased(), "MEMORY")
    }
}
