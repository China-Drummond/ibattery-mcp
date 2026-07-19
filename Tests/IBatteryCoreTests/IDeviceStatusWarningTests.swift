import XCTest
@testable import IBatteryCore

final class IDeviceStatusWarningTests: XCTestCase {
    func testIDeviceStatusWarning_toolsNotInstalled_returnsInstallMessage() {
        let status = IDeviceStatus(toolsInstalled: false, connectedButUnreadableCount: 0)
        let warning = iDeviceStatusWarning(status: status)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("brew install libimobiledevice") == true)
    }

    func testIDeviceStatusWarning_unreadableDevices_returnsTrustMessage() {
        let status = IDeviceStatus(toolsInstalled: true, connectedButUnreadableCount: 1)
        let warning = iDeviceStatusWarning(status: status)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.lowercased().contains("trust") == true)
    }

    func testIDeviceStatusWarning_allClear_returnsNil() {
        let status = IDeviceStatus(toolsInstalled: true, connectedButUnreadableCount: 0)
        XCTAssertNil(iDeviceStatusWarning(status: status))
    }
}
