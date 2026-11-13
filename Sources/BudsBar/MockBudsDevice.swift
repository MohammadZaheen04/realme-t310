import Foundation
import Observation

/// Mock device implementation conforming to `BudsDeviceProtocol` for testing the verified
/// features with simulated data.
@Observable
public final class MockBudsDevice: BudsDeviceProtocol {

    // MARK: - Published State

    public var name: String = "realme Buds Air 6 Pro"
    public var isPaired: Bool = true
    public var isConnected: Bool = true
    public var isAvailable: Bool = true
    public var isControlChannelOpen: Bool = true
    public var isBusy: Bool = false
    public var lastError: String?

    public var battery: BatteryState = BatteryState(
        left: 85,
        right: 90,
        enclosure: 65,
        isLeftCharging: false,
        isRightCharging: false,
        isEnclosureCharging: true
    )

    public var placement: PlacementState = PlacementState(
        left: .inUse,
        right: .inUse
    )

    public var mode: NoiseMode? = .noiseCancellation
    public var ancLevel: ANCLevel? = .medium

    public var deviceInfo: DeviceInfoState = DeviceInfoState(
        modelName: "realme Buds Air 6 Pro",
        bluetoothAddress: "B0:38:E2:DE:E6:16",
        firmwareVersion: "v1.1.0.48"
    )

    public var availableDevices: [DeviceEntry] {
        [
            DeviceEntry(
                name: self.name,
                address: deviceInfo.bluetoothAddress,
                isConnected: isConnected
            )
        ]
    }

    public var onStateChange: (() -> Void)?

    // MARK: - Persistence Keys

    private enum Keys {
        static let name = "mock_deviceName"
        static let mode = "mock_noiseMode"
        static let ancLevel = "mock_ancLevel"
        static let isConnected = "mock_isConnected"
    }

    // MARK: - Init & Persistence

    public init() {
        loadPersistedSettings()
    }

    private func loadPersistedSettings() {
        let defaults = UserDefaults.standard

        if let savedName = defaults.string(forKey: Keys.name), !savedName.isEmpty {
            self.name = savedName
        }
        if let savedModeRaw = defaults.string(forKey: Keys.mode),
           let savedMode = NoiseMode(rawValue: savedModeRaw) {
            self.mode = savedMode
        }
        if let savedLevelRaw = defaults.string(forKey: Keys.ancLevel),
           let savedLevel = ANCLevel(rawValue: savedLevelRaw) {
            self.ancLevel = savedLevel
        }
        if defaults.object(forKey: Keys.isConnected) != nil {
            self.isConnected = defaults.bool(forKey: Keys.isConnected)
        }
    }

    // MARK: - Actions

    public func connect() {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        onStateChange?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.isControlChannelOpen = true
            self.isBusy = false
            UserDefaults.standard.set(true, forKey: Keys.isConnected)
            self.onStateChange?()
        }
    }

    public func disconnect() {
        guard !isBusy else { return }
        isBusy = true
        onStateChange?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.isConnected = false
            self.isControlChannelOpen = false
            self.isBusy = false
            UserDefaults.standard.set(false, forKey: Keys.isConnected)
            self.onStateChange?()
        }
    }

    public func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.name = trimmed
        UserDefaults.standard.set(trimmed, forKey: Keys.name)
        onStateChange?()
    }

    public func forgetDevice() {
        disconnect()
        isPaired = false
        onStateChange?()
    }

    public func selectDevice(address: String) {
        // Mock device selection
        onStateChange?()
    }

    public func scanForDevices() {
        // Mock scan
        onStateChange?()
    }

    public func set(mode: NoiseMode) {
        self.mode = mode
        if mode == .noiseCancellation && self.ancLevel == nil {
            self.ancLevel = .medium
        }
        UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
        onStateChange?()
    }

    public func set(ancLevel: ANCLevel) {
        self.mode = .noiseCancellation
        self.ancLevel = ancLevel
        UserDefaults.standard.set(NoiseMode.noiseCancellation.rawValue, forKey: Keys.mode)
        UserDefaults.standard.set(ancLevel.rawValue, forKey: Keys.ancLevel)
        onStateChange?()
    }

    public func refreshConnectionState() {
        onStateChange?()
    }

    public func queryBattery() {
        // Mock query preserves battery values
    }
}
