// Tests/IBatteryCoreTests/AirPodsBatteryTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class AirPodsBatteryTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testParse_allThreeFieldsPresent_emitsThreeEntries() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Someone's AirPods4": {
                    "device_address": "AA:BB:CC:DD:EE:FF",
                    "device_batteryLevelCase": "51%",
                    "device_batteryLevelLeft": "100%",
                    "device_batteryLevelRight": "97%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result.count, 3)

        let left = result.first { $0.id == "aa:bb:cc:dd:ee:ff-left" }
        XCTAssertEqual(left?.name, "Someone's AirPods4 (Left)")
        XCTAssertEqual(left?.kind, .airpods)
        XCTAssertEqual(left?.percentage, 100)
        XCTAssertNil(left?.isCharging)
        XCTAssertEqual(left?.lastUpdated, fixedDate)

        let right = result.first { $0.id == "aa:bb:cc:dd:ee:ff-right" }
        XCTAssertEqual(right?.name, "Someone's AirPods4 (Right)")
        XCTAssertEqual(right?.percentage, 97)

        let caseEntry = result.first { $0.id == "aa:bb:cc:dd:ee:ff-case" }
        XCTAssertEqual(caseEntry?.name, "Someone's AirPods4 (Case)")
        XCTAssertEqual(caseEntry?.percentage, 51)
    }

    func testParse_onlyCasePresent_emitsSingleCaseEntry() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Someone's AirPods4": {
                    "device_address": "AA:BB:CC:DD:EE:FF",
                    "device_batteryLevelCase": "51%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "aa:bb:cc:dd:ee:ff-case")
        XCTAssertEqual(result[0].percentage, 51)
    }

    func testParse_nonAppleVendorID_isSkipped() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Jabra Elite 75t": {
                    "device_address": "11:22:33:44:55:66",
                    "device_batteryLevelLeft": "80%",
                    "device_batteryLevelRight": "80%",
                    "device_vendorID": "0x0067"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_malformedPercentageString_skipsThatFieldOnly() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Someone's AirPods4": {
                    "device_address": "AA:BB:CC:DD:EE:FF",
                    "device_batteryLevelLeft": "not-a-number",
                    "device_batteryLevelRight": "97%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "aa:bb:cc:dd:ee:ff-right")
    }

    func testParse_missingDeviceAddress_skipsEntry() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_not_connected": [
                {
                  "Someone's AirPods4": {
                    "device_batteryLevelLeft": "100%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_missingConnectedAndNotConnectedKeys_returnsEmpty() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "controller_properties": { "controller_address": "D0:11:E5:87:61:EB" }
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_emptyTopLevelArray_returnsEmpty() {
        let json = """
        { "SPBluetoothDataType": [] }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_malformedJSON_returnsEmptyWithoutCrashing() {
        let result = parseSystemProfilerBluetoothJSON(Data("not json".utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result, [])
    }

    func testParse_bothConnectedAndNotConnectedDevicesAreIncluded() {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "Connected AirPods": {
                    "device_address": "11:11:11:11:11:11",
                    "device_batteryLevelLeft": "60%",
                    "device_vendorID": "0x004C"
                  }
                }
              ],
              "device_not_connected": [
                {
                  "Cached AirPods": {
                    "device_address": "22:22:22:22:22:22",
                    "device_batteryLevelCase": "40%",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """
        let result = parseSystemProfilerBluetoothJSON(Data(json.utf8), fetchedAt: fixedDate)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { $0.id == "11:11:11:11:11:11-left" })
        XCTAssertTrue(result.contains { $0.id == "22:22:22:22:22:22-case" })
    }
}
