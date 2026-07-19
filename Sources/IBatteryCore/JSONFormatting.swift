// Sources/IBatteryCore/JSONFormatting.swift
import Foundation

public let deviceJSONEncoder: JSONEncoder = {
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

public let deviceJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()
