import XCTest
import Foundation
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

    // MARK: - SingleResumeGate

    func testSingleResumeGate_firstCallReturnsTrue() {
        let gate = SingleResumeGate()
        XCTAssertTrue(gate.tryResume())
    }

    func testSingleResumeGate_subsequentCallsReturnFalse() {
        let gate = SingleResumeGate()
        XCTAssertTrue(gate.tryResume())
        XCTAssertFalse(gate.tryResume())
        XCTAssertFalse(gate.tryResume())
    }

    func testSingleResumeGate_concurrentTryResume_exactlyOneCallerWins() {
        let gate = SingleResumeGate()
        let winCountLock = NSLock()
        var winCount = 0
        let group = DispatchGroup()
        for _ in 0..<200 {
            group.enter()
            DispatchQueue.global().async {
                if gate.tryResume() {
                    winCountLock.lock()
                    winCount += 1
                    winCountLock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        // The real-world race this guards is exactly two callers (the actual
        // fetch finishing vs. the timeout firing), but hammering it with 200
        // concurrent callers is a stronger stress test of the same mutual-
        // exclusion property: no matter how many threads race, exactly one
        // may ever win.
        XCTAssertEqual(winCount, 1, "exactly one concurrent tryResume() call should return true")
    }
}
