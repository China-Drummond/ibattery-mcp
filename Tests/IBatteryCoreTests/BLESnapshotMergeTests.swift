// Tests/IBatteryCoreTests/BLESnapshotMergeTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class BLESnapshotMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        id: String, name: String, kind: DeviceBatteryInfo.Kind,
        percentage: Int = 50, isCharging: Bool? = nil, age: TimeInterval = 0,
        inCase: Bool? = nil, lidOpen: Bool? = nil
    ) -> DeviceBatteryInfo {
        DeviceBatteryInfo(
            id: id, name: name, kind: kind, percentage: percentage,
            isCharging: isCharging, lastUpdated: now.addingTimeInterval(-age),
            inCase: inCase, lidOpen: lidOpen
        )
    }

    func testFreshBLEAirPods_winsOverProfiler_andKeepsProfilerID() {
        let merged = mergeBLESnapshot([
            entry(id: "aa:bb:cc:dd:ee:ff-left", name: "Pods (Left)", kind: .airpods, percentage: 90),
            entry(id: "ble-uuid1-left", name: "Pods (Left)", kind: .airpods, percentage: 85, isCharging: true, age: 30, inCase: true)
        ], now: now)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "aa:bb:cc:dd:ee:ff-left")
        XCTAssertEqual(merged[0].percentage, 85)
        XCTAssertEqual(merged[0].isCharging, true)
        XCTAssertEqual(merged[0].inCase, true)
        XCTAssertFalse(merged[0].stale)
    }

    func testStaleBLEAirPods_profilerLevelWithBLEInCaseAndHonestTimestamp() {
        let merged = mergeBLESnapshot([
            entry(id: "aa:bb:cc:dd:ee:ff-left", name: "Pods (Left)", kind: .airpods, percentage: 90, isCharging: nil),
            entry(id: "ble-uuid1-left", name: "Pods (Left)", kind: .airpods, percentage: 85, isCharging: true, age: 700, inCase: false)
        ], now: now)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "aa:bb:cc:dd:ee:ff-left")
        XCTAssertEqual(merged[0].percentage, 90)          // profiler level
        XCTAssertNil(merged[0].isCharging)                // spec §4.2
        XCTAssertEqual(merged[0].inCase, false)           // BLE last-known state
        XCTAssertEqual(merged[0].lastUpdated, now.addingTimeInterval(-700))
        XCTAssertTrue(merged[0].stale)                    // 700s > 120s threshold
    }

    func testFreshBLEOnlyAirPods_keptWithBLEID() {
        let merged = mergeBLESnapshot([
            entry(id: "ble-uuid1-case", name: "Pods (Case)", kind: .airpods, percentage: 70, age: 30, lidOpen: true)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "ble-uuid1-case")
        XCTAssertEqual(merged[0].lidOpen, true)
    }

    func testStaleBLEOnlyAirPods_keptAndMarkedStale() {
        let merged = mergeBLESnapshot([
            entry(id: "ble-uuid1-left", name: "Pods (Left)", kind: .airpods, age: 700)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].stale)
    }

    func testProfilerOnlyAirPods_passesThroughUnchanged() {
        let profiler = entry(id: "aa:bb:cc:dd:ee:ff-right", name: "Pods (Right)", kind: .airpods, percentage: 40)
        let merged = mergeBLESnapshot([profiler], now: now)
        XCTAssertEqual(merged, [profiler])
    }

    func testBLEIOSDevice_droppedWhenOfficialEntrySameName() {
        let merged = mergeBLESnapshot([
            entry(id: "00008150-FAKEUDID0001", name: "Test iPhone", kind: .iosDevice, percentage: 80, isCharging: false),
            entry(id: "ble-uuid2", name: "Test iPhone", kind: .iosDevice, percentage: 79)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "00008150-FAKEUDID0001")
    }

    func testBLEIOSDevice_keptWhenNoOfficialEntry() {
        let merged = mergeBLESnapshot([
            entry(id: "ble-uuid2", name: "Test iPhone", kind: .iosDevice, percentage: 79)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "ble-uuid2")
        XCTAssertEqual(merged[0].kind, .iosDevice)
    }

    func testDuplicateIDs_firstOccurrenceWins() {
        // Old-helper skew: "snapshot" answered by the generic-scan branch
        // duplicates entries BLEBatterySource already returned.
        let merged = mergeBLESnapshot([
            entry(id: "uuid3", name: "Test Mouse", kind: .bleGeneric, percentage: 60),
            entry(id: "uuid3", name: "Test Mouse", kind: .bleGeneric, percentage: 60)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
    }

    func testNonAirPodsNonIOSKinds_passThrough() {
        let mac = entry(id: "mac-internal", name: "MacBook Pro", kind: .mac, percentage: 95)
        let watch = entry(id: "watch-udid", name: "Watch7,2", kind: .watch, percentage: 88)
        let merged = mergeBLESnapshot([mac, watch], now: now)
        XCTAssertEqual(merged, [mac, watch])
    }
}
