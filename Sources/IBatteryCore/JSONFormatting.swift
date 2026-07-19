// Sources/IBatteryCore/JSONFormatting.swift
import Foundation

let deviceJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

func encodeDevicesAsText(_ devices: [DeviceBatteryInfo]) -> String {
    guard let data = try? deviceJSONEncoder.encode(devices),
          let json = String(data: data, encoding: .utf8)
    else {
        return "[]"
    }
    return json
}
