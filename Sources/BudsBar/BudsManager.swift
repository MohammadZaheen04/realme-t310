import Foundation
import Observation

/// Unified manager conforming to `BudsDeviceProtocol` that acts as the single entry point
/// for device communication, providing seamless switching between real Bluetooth hardware
/// and the interactive mock implementation.
@Observable
final class BudsManager: BudsDeviceProtocol {

    static let shared = BudsManager()

    let realBuds: Buds
    let mockBuds: MockBudsDevice

    var useMockDevice: Bool {
        didSet {
            UserDefaults.standard.set(useMockDevice, forKey: "budsbar_use_mock_device")
            syncWithActiveDevice()
            onStateChange?()
        }
    }

    var activeDevice: any BudsDeviceProtocol {
        useMockDevice ? mockBuds : realBuds
    }

    // MARK: - Forwarded Observable State

    var name: String = ""
    var isPaired: Bool = false
    var isConnected: Bool = false
    var isAvailable: Bool = false
    var isControlChannelOpen: Bool = false
    var isBusy: Bool = false
    var lastError: String?

    var battery: BatteryState = BatteryState()
    var placement: PlacementState = PlacementState()

    var mode: NoiseMode?
    var ancLevel: ANCLevel?

    var deviceInfo: DeviceInfoState = DeviceInfoState()

    var onStateChange: (() -> Void)?

    init() {
        self.realBuds = Buds()
        self.mockBuds = MockBudsDevice()

        let envForcedMock = ProcessInfo.processInfo.environment["BUDSBAR_MOCK"] != nil
        let savedMock = UserDefaults.standard.object(forKey: "budsbar_use_mock_device") as? Bool
        // Default to mock if environment variable set, or if user explicitly chose it,
        // or if real earbuds are not currently connected.
        self.useMockDevice = envForcedMock || (savedMock ?? (!realBuds.isConnected))

        // Hook up state callbacks from both backends
        self.realBuds.onStateChange = { [weak self] in
            guard let self, !self.useMockDevice else { return }
            self.syncWithActiveDevice()
            self.onStateChange?()
        }

        self.mockBuds.onStateChange = { [weak self] in
            guard let self, self.useMockDevice else { return }
            self.syncWithActiveDevice()
            self.onStateChange?()
        }

        syncWithActiveDevice()
    }

    func syncWithActiveDevice() {
        let dev = activeDevice
        self.name = dev.name
        self.isPaired = dev.isPaired
        self.isConnected = dev.isConnected
        self.isAvailable = dev.isAvailable
        self.isControlChannelOpen = dev.isControlChannelOpen
        self.isBusy = dev.isBusy
        self.lastError = dev.lastError

        self.battery = dev.battery
        self.placement = dev.placement

        self.mode = dev.mode
        self.ancLevel = dev.ancLevel

        self.deviceInfo = dev.deviceInfo
    }

    // MARK: - Forwarded Methods

    func connect() {
        activeDevice.connect()
        syncWithActiveDevice()
    }

    func disconnect() {
        activeDevice.disconnect()
        syncWithActiveDevice()
    }

    func rename(to newName: String) {
        activeDevice.rename(to: newName)
        syncWithActiveDevice()
    }

    func forgetDevice() {
        activeDevice.forgetDevice()
        syncWithActiveDevice()
    }

    func set(mode: NoiseMode) {
        activeDevice.set(mode: mode)
        syncWithActiveDevice()
    }

    func set(ancLevel: ANCLevel) {
        activeDevice.set(ancLevel: ancLevel)
        syncWithActiveDevice()
    }

    func refreshConnectionState() {
        activeDevice.refreshConnectionState()
        syncWithActiveDevice()
    }

    func queryBattery() {
        activeDevice.queryBattery()
        syncWithActiveDevice()
    }

    func shutdown() {
        realBuds.shutdown()
    }
}
