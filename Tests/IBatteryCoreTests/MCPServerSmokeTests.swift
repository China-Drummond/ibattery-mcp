// Tests/IBatteryCoreTests/MCPServerSmokeTests.swift
import XCTest

final class MCPServerSmokeTests: XCTestCase {
    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Couldn't find the products directory")
    }

    private var executableURL: URL {
        productsDirectory.appendingPathComponent("ibattery-mcp")
    }

    func testServerRespondsToToolsList() throws {
        let process = Process()
        process.executableURL = executableURL
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        try process.run()
        defer { process.terminate() }

        let initRequest = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-client","version":"0.1"}}}"# + "\n"
        inPipe.fileHandleForWriting.write(initRequest.data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)

        let initializedNotification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
        inPipe.fileHandleForWriting.write(initializedNotification.data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.2)

        let listRequest = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"# + "\n"
        inPipe.fileHandleForWriting.write(listRequest.data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)

        let outputData = outPipe.fileHandleForReading.availableData
        let response = String(data: outputData, encoding: .utf8) ?? ""
        XCTAssertTrue(response.contains("get_all_devices_status"), "Expected get_all_devices_status in tools/list, got: \(response)")
        XCTAssertTrue(response.contains("get_device_battery"), "Expected get_device_battery in tools/list, got: \(response)")
        XCTAssertTrue(response.contains("list_known_devices"), "Expected list_known_devices in tools/list, got: \(response)")
    }
}
