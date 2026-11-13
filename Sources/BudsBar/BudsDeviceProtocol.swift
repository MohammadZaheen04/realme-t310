import Foundation
import Observation
import SwiftUI

// MARK: - Enums & Models

public enum NoiseMode: String, CaseIterable, Identifiable, Codable {
    case noiseCancellation
    case off
    case transparency

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .noiseCancellation: return "ANC"
        case .off: return "Off"
        case .transparency: return "Transparency"
        }
    }

    /// Distinct icons:
    /// ANC = sound wave with a slash ("waveform.slash")
    /// Off = plain ear ("ear")
    /// Transparency = ear with sound waves ("ear.and.waveform")
    public var symbol: String {
        switch self {
        case .noiseCancellation: return "waveform.slash"
        case .off: return "ear"
        case .transparency: return "ear.and.waveform"
        }
    }

    public init?(wire: UInt8) {
        switch wire {
        case 0x01: self = .off
        case 0x02: self = .transparency
        case 0x04, 0x08, 0x10, 0x20: self = .noiseCancellation
        default: return nil
        }
    }

    public var wire: UInt8 {
        switch self {
        case .off: return 0x01
        case .transparency: return 0x02
        case .noiseCancellation: return ANCLevel.strong.wire
        }
    }
}

public enum ANCLevel: String, CaseIterable, Identifiable, Codable {
    case light
    case medium
    case strong
    case adaptive

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .light: return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        case .adaptive: return "Adaptive"
        }
    }

    public var detail: String {
        switch self {
        case .light: return "Quieter places — home and quiet office"
        case .medium: return "Noisy places — streets and cafes"
        case .strong: return "Very noisy places — planes and trains"
        case .adaptive: return "Automatically adjusts intensity to your surroundings"
        }
    }

    public var wire: UInt8 {
        switch self {
        case .light: return 0x04
        case .strong: return 0x08
        case .medium: return 0x10
        case .adaptive: return 0x20
        }
    }

    public init?(wire: UInt8) {
        switch wire {
        case 0x04: self = .light
        case 0x08: self = .strong
        case 0x10: self = .medium
        case 0x20: self = .adaptive
        default: return nil
        }
    }

    // Compatibility aliases
    public static var mild: ANCLevel { .light }
    public static var moderate: ANCLevel { .medium }
    public static var max: ANCLevel { .strong }
}

public enum BudsPlacement: UInt8, Codable {
    case inCase = 0x00
    case inUse = 0x03
}

public struct BatteryState: Equatable, Codable {
    public var left: Int?
    public var right: Int?
    public var enclosure: Int?
    public var isLeftCharging: Bool = false
    public var isRightCharging: Bool = false
    public var isEnclosureCharging: Bool = false

    public init(
        left: Int? = nil,
        right: Int? = nil,
        enclosure: Int? = nil,
        isLeftCharging: Bool = false,
        isRightCharging: Bool = false,
        isEnclosureCharging: Bool = false
    ) {
        self.left = left
        self.right = right
        self.enclosure = enclosure
        self.isLeftCharging = isLeftCharging
        self.isRightCharging = isRightCharging
        self.isEnclosureCharging = isEnclosureCharging
    }
}

public struct PlacementState: Equatable, Codable {
    public var left: BudsPlacement?
    public var right: BudsPlacement?

    public init(left: BudsPlacement? = nil, right: BudsPlacement? = nil) {
        self.left = left
        self.right = right
    }
}

public struct DeviceInfoState: Equatable, Codable {
    public var modelName: String = "realme Buds"
    public var bluetoothAddress: String = "B0:38:E2:DE:E6:16"
    public var firmwareVersion: String = "v1.0"

    public init(
        modelName: String = "realme Buds",
        bluetoothAddress: String = "B0:38:E2:DE:E6:16",
        firmwareVersion: String = "v1.0"
    ) {
        self.modelName = modelName
        self.bluetoothAddress = bluetoothAddress
        self.firmwareVersion = firmwareVersion
    }
}

public struct DeviceEntry: Identifiable, Equatable, Hashable {
    public var id: String { address }
    public let name: String
    public let address: String
    public let isConnected: Bool

    public init(name: String, address: String, isConnected: Bool) {
        self.name = name
        self.address = address
        self.isConnected = isConnected
    }
}

// MARK: - Device Protocol (Working Verified Features)

public protocol BudsDeviceProtocol: AnyObject, Observable {
    var name: String { get set }
    var isPaired: Bool { get }
    var isConnected: Bool { get }
    var isAvailable: Bool { get }
    var isControlChannelOpen: Bool { get }
    var isBusy: Bool { get }
    var lastError: String? { get set }

    var battery: BatteryState { get set }
    var placement: PlacementState { get set }

    var mode: NoiseMode? { get set }
    var ancLevel: ANCLevel? { get set }

    var deviceInfo: DeviceInfoState { get set }
    var availableDevices: [DeviceEntry] { get }

    var onStateChange: (() -> Void)? { get set }

    func connect()
    func disconnect()
    func rename(to newName: String)
    func forgetDevice()
    func selectDevice(address: String)
    func scanForDevices()
    func set(mode: NoiseMode)
    func set(ancLevel: ANCLevel)
    func refreshConnectionState()
    func queryBattery()
}
