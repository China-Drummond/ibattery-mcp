// Tests/IBatteryCoreTests/DeviceBatteryInfoTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class DeviceBatteryInfoTests: XCTestCase {
    func testInit_lastUpdatedLocal_roundTripsToSameInstantAsLastUpdated() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let info = DeviceBatteryInfo(
            id: "x",
            name: "X",
            kind: .mac,
            percentage: 50,
            isCharging: nil,
            lastUpdated: date
        )

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        let parsedBack = parser.date(from: info.lastUpdatedLocal)

        XCTAssertNotNil(parsedBack)
        XCTAssertEqual(parsedBack?.timeIntervalSince1970 ?? -1, date.timeIntervalSince1970, accuracy: 1.0)
    }

    func testDecode_legacyJSONWithoutLastUpdatedLocalKey_stillDecodes() {
        let json = """
        {"id":"abc","name":"Test Mouse","kind":"bleGeneric","percentage":72,"isCharging":null,"lastUpdated":"2026-07-19T08:00:00Z","stale":false}
        """
        let decoded = try? deviceJSONDecoder.decode(DeviceBatteryInfo.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.id, "abc")
        XCTAssertFalse(decoded?.lastUpdatedLocal.isEmpty ?? true)
    }

    func testDecode_missingStaleKey_throws() {
        let json = """
        {"id":"abc","name":"Test Mouse","kind":"bleGeneric","percentage":72,"isCharging":null,"lastUpdated":"2026-07-19T08:00:00Z"}
        """
        XCTAssertThrowsError(try deviceJSONDecoder.decode(DeviceBatteryInfo.self, from: Data(json.utf8)))
    }

    func testEncode_includesLastUpdatedLocalKey() throws {
        let info = DeviceBatteryInfo(
            id: "x",
            name: "X",
            kind: .mac,
            percentage: 50,
            isCharging: nil,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try deviceJSONEncoder.encode(info)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"lastUpdatedLocal\""))
    }

    func testEquatable_sameLastUpdated_producesEqualLastUpdatedLocal() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = DeviceBatteryInfo(id: "x", name: "X", kind: .mac, percentage: 50, isCharging: nil, lastUpdated: date)
        let second = DeviceBatteryInfo(id: "x", name: "X", kind: .mac, percentage: 50, isCharging: nil, lastUpdated: date)
        XCTAssertEqual(first, second)
    }

    func testEncode_omitsInCaseAndLidOpenKeysWhenNil() throws {
        let info = DeviceBatteryInfo(
            id: "x", name: "X", kind: .airpods, percentage: 50,
            isCharging: nil, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let json = String(data: try deviceJSONEncoder.encode(info), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("inCase"))
        XCTAssertFalse(json.contains("lidOpen"))
    }

    func testEncode_includesInCaseAndLidOpenWhenSet() throws {
        let info = DeviceBatteryInfo(
            id: "x", name: "X", kind: .airpods, percentage: 50,
            isCharging: true, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            inCase: true, lidOpen: false
        )
        let json = String(data: try deviceJSONEncoder.encode(info), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"inCase\":true"))
        XCTAssertTrue(json.contains("\"lidOpen\":false"))
    }

    func testDecode_legacyJSONWithoutInCaseKeys_decodesWithNil() throws {
        let json = """
        {"id":"abc","name":"Pods (Left)","kind":"airpods","percentage":72,"isCharging":null,"lastUpdated":"2026-07-19T08:00:00Z","stale":false}
        """
        let decoded = try deviceJSONDecoder.decode(DeviceBatteryInfo.self, from: Data(json.utf8))
        XCTAssertNil(decoded.inCase)
        XCTAssertNil(decoded.lidOpen)
    }

    func testCodableRoundTrip_preservesInCaseAndLidOpen() throws {
        let info = DeviceBatteryInfo(
            id: "x", name: "X", kind: .airpods, percentage: 50,
            isCharging: false, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            inCase: false, lidOpen: true
        )
        let decoded = try deviceJSONDecoder.decode(DeviceBatteryInfo.self, from: deviceJSONEncoder.encode(info))
        XCTAssertEqual(decoded.inCase, false)
        XCTAssertEqual(decoded.lidOpen, true)
    }
}
