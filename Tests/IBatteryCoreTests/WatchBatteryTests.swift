import XCTest
import CLibimobiledevice
@testable import IBatteryCore

final class WatchBatteryTests: XCTestCase {
    func testParseUDIDList_multipleEntries() {
        let plist = plist_new_array()
        plist_array_append_item(plist, plist_new_string("00008310-001A2C3D4E5F001E"))
        plist_array_append_item(plist, plist_new_string("00008310-001A2C3D4E5F002F"))
        defer { plist_free(plist) }

        XCTAssertEqual(parseUDIDList(fromPairedDevicesPlist: plist), [
            "00008310-001A2C3D4E5F001E",
            "00008310-001A2C3D4E5F002F"
        ])
    }

    func testParseUDIDList_emptyArray_returnsEmpty() {
        let plist = plist_new_array()
        defer { plist_free(plist) }
        XCTAssertEqual(parseUDIDList(fromPairedDevicesPlist: plist), [])
    }

    func testParseUDIDList_nilPlist_returnsEmpty() {
        XCTAssertEqual(parseUDIDList(fromPairedDevicesPlist: nil), [])
    }

    func testParseWatchBatteryValue_validValues() {
        let capacityPlist = plist_new_uint(66)
        let chargingPlist = plist_new_bool(1)
        defer {
            plist_free(capacityPlist)
            plist_free(chargingPlist)
        }

        let result = parseWatchBatteryValue(fromCapacityPlist: capacityPlist, chargingPlist: chargingPlist)
        XCTAssertEqual(result?.percentage, 66)
        XCTAssertEqual(result?.isCharging, true)
    }

    func testParseWatchBatteryValue_nilCapacity_returnsNil() {
        XCTAssertNil(parseWatchBatteryValue(fromCapacityPlist: nil, chargingPlist: nil))
    }

    func testParseWatchBatteryValue_nilCharging_defaultsToFalse() {
        let capacityPlist = plist_new_uint(50)
        defer { plist_free(capacityPlist) }

        let result = parseWatchBatteryValue(fromCapacityPlist: capacityPlist, chargingPlist: nil)
        XCTAssertEqual(result?.percentage, 50)
        XCTAssertEqual(result?.isCharging, false)
    }

    func testParseWatchProductType_validString() {
        let plist = plist_new_string("Watch6,6")
        defer { plist_free(plist) }
        XCTAssertEqual(parseWatchProductType(fromPlist: plist), "Watch6,6")
    }

    func testParseWatchProductType_nilPlist_returnsNil() {
        XCTAssertNil(parseWatchProductType(fromPlist: nil))
    }
}
