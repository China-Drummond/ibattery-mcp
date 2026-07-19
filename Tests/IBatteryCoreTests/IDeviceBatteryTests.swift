// Tests/IBatteryCoreTests/IDeviceBatteryTests.swift
import XCTest
import Foundation
@testable import IBatteryCore

final class IDeviceBatteryTests: XCTestCase {
    func testParseDeviceIdList_multipleUdids() {
        let output = "00008030-000C1234ABCD002E\n00008110-001A2345BCDE003F\n"
        XCTAssertEqual(parseDeviceIdList(output), [
            "00008030-000C1234ABCD002E",
            "00008110-001A2345BCDE003F"
        ])
    }

    func testParseDeviceIdList_emptyOutput_returnsEmpty() {
        XCTAssertEqual(parseDeviceIdList(""), [])
    }

    func testParseDeviceIdList_trailingBlankLinesIgnored() {
        XCTAssertEqual(parseDeviceIdList("00008030-000C1234ABCD002E\n\n\n"), ["00008030-000C1234ABCD002E"])
    }

    func testParseBatteryPlist_validPlist_returnsCapacityAndCharging() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>BatteryCurrentCapacity</key>
            <integer>87</integer>
            <key>BatteryIsCharging</key>
            <true/>
        </dict>
        </plist>
        """
        let result = parseBatteryPlist(Data(xml.utf8))
        XCTAssertEqual(result?.percentage, 87)
        XCTAssertEqual(result?.isCharging, true)
    }

    func testParseBatteryPlist_missingCapacityKey_returnsNil() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>BatteryIsCharging</key>
            <false/>
        </dict>
        </plist>
        """
        XCTAssertNil(parseBatteryPlist(Data(xml.utf8)))
    }

    func testParseBatteryPlist_malformedData_returnsNil() {
        XCTAssertNil(parseBatteryPlist(Data("not a plist".utf8)))
    }

    func testParseBatteryPlist_missingChargingKey_defaultsToFalse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>BatteryCurrentCapacity</key>
            <integer>50</integer>
        </dict>
        </plist>
        """
        let result = parseBatteryPlist(Data(xml.utf8))
        XCTAssertEqual(result?.percentage, 50)
        XCTAssertEqual(result?.isCharging, false)
    }

    func testParseDeviceNamePlist_validPlist_returnsName() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DeviceName</key>
            <string>Drummond's iPhone</string>
            <key>DeviceClass</key>
            <string>iPhone</string>
        </dict>
        </plist>
        """
        XCTAssertEqual(parseDeviceNamePlist(Data(xml.utf8)), "Drummond's iPhone")
    }

    func testParseDeviceNamePlist_missingKey_returnsNil() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>DeviceClass</key>
            <string>iPhone</string>
        </dict>
        </plist>
        """
        XCTAssertNil(parseDeviceNamePlist(Data(xml.utf8)))
    }
}
