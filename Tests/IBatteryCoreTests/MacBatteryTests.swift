import XCTest
@testable import IBatteryCore

final class MacBatteryTests: XCTestCase {
    func testParseMacBatteryDescription_returnsCorrectInfo() {
        let description: [String: Any] = [
            kIOPSCurrentCapacityKeyForTest: 87,
            kIOPSIsChargingKeyForTest: true
        ]
        let info = parseMacBatteryDescription(description)
        XCTAssertEqual(info?.percentage, 87)
        XCTAssertEqual(info?.isCharging, true)
        XCTAssertEqual(info?.kind, .mac)
    }

    func testParseMacBatteryDescription_missingCapacity_returnsNil() {
        let description: [String: Any] = [:]
        XCTAssertNil(parseMacBatteryDescription(description))
    }
}

// Test-only string constants mirroring the real IOKit key names, so this
// test file doesn't need to import IOKit.ps itself.
let kIOPSCurrentCapacityKeyForTest = "Current Capacity"
let kIOPSIsChargingKeyForTest = "Is Charging"
