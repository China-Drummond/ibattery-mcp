import Foundation

public struct DeviceBatteryInfo: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case mac
        case bleGeneric
        case iosDevice
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let percentage: Int
    public let isCharging: Bool?
    public let lastUpdated: Date
    public let stale: Bool

    public init(
        id: String,
        name: String,
        kind: Kind,
        percentage: Int,
        isCharging: Bool?,
        lastUpdated: Date,
        stale: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.percentage = percentage
        self.isCharging = isCharging
        self.lastUpdated = lastUpdated
        self.stale = stale
    }
}
