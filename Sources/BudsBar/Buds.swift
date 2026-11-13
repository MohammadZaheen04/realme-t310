import Foundation
import IOBluetooth
import Observation

/// Live state of the earbuds plus the Bluetooth plumbing that produces it.
///
/// Two independent links are involved:
///   - the baseband connection (`openConnection`/`closeConnection`), which is what the
///     power toggle in the UI drives, and
///   - the vendor RFCOMM control channel (`oppointeraction`), which carries noise-control
///     and per-bud battery. The latter only exists while the former is up.
@Observable
final class Buds: NSObject, IOBluetoothRFCOMMChannelDelegate, BudsDeviceProtocol {

    /// Raw protocol logging, off unless asked for — the buds push status every few seconds.
    static let isTracing = ProcessInfo.processInfo.environment["BUDSBAR_TRACE"] != nil

    /// SDP service UUID for OPPO/realme's `oppointeraction` control service.
    /// realme is an OPPO sub-brand and shares the protocol.
    private static let controlServiceUUID: [UInt8] = [
        0x00, 0x00, 0x07, 0x9a, 0xd1, 0x02, 0x11, 0xe1,
        0x9b, 0x23, 0x00, 0x02, 0x5b, 0x00, 0xa5, 0xa5,
    ]

    // MARK: - Published state

    static let fallbackName = "Earbuds"

    var name: String = Buds.fallbackName
    /// Guards the one-shot background lookup in `syncName`; cleared on a new link.
    private var hasReadDisplayName = false
    var isConnected = false
    /// True once the vendor control channel is open — noise control needs it.
    var isControlChannelOpen = false
    var battery = BatteryState()
    var placement = PlacementState()
    var mode: NoiseMode?
    /// How hard noise cancellation is working. nil while the buds are on Smart, which this
    /// app does not model, or before the first report has arrived.
    var ancLevel: ANCLevel?
    var deviceInfo: DeviceInfoState = DeviceInfoState()
    /// Set while a connect/disconnect is in flight so the toggle can't be double-fired.
    var isBusy = false
    var lastError: String?

    /// Set when the power toggle was used to switch the buds off.
    ///
    /// Sticky, and it outranks every other signal — including frames still arriving on the
    /// control channel. A worn earbud re-pages the Mac within a second of `closeConnection`
    /// and macOS brings the audio link straight back up, so anything that reads the link as
    /// evidence of intent ends up undoing the switch-off the user just asked for. Off means
    /// off until the toggle is used again; only `connect()` clears this.
    private(set) var isSwitchedOff = false

    /// Set when a connect the *user* asked for failed, so the item stays on screen with the
    /// error on it. Deliberately not `isSwitchedOff`: that flag also stops the auto-connect
    /// poll, and the user asked for on — the buds are routinely slow to accept the first page
    /// after being dropped, so the retry is exactly what recovers it.
    private var didFailUserConnect = false

    /// Whether the menu bar item should exist at all.
    ///
    /// Classic Bluetooth has no way to ask whether a device is nearby short of paging it,
    /// and paging *is* connecting — `remoteNameRequest` answers from cache, so it cannot
    /// tell a closed case from an open one. So availability is inferred rather than probed:
    /// either the buds are connected, or they were switched off deliberately and the user
    /// needs the toggle to switch them back on. Buds sitting in a shut case are neither, and
    /// the item disappears.
    ///
    /// Busy counts too — but only when the attempt is the user's. Flipping the toggle back
    /// on clears `isSwitchedOff` before the link exists, and without the busy term the item
    /// would vanish the moment it was flipped. The background retry must NOT get the same
    /// courtesy: against a shut case openConnection() blocks for the full page timeout, so
    /// counting auto attempts kept resurfacing the red icon for ~10s of every 20.
    /// With nothing paired the item stays put regardless, so the panel can say why instead
    /// of the app being invisible and looking broken.
    var isAvailable: Bool {
        !isPaired || isConnected || isSwitchedOff || didFailUserConnect
            || (isBusy && !isAutoConnecting)
    }

    /// True while the in-flight connect attempt came from the poll rather than the user.
    private var isAutoConnecting = false

    /// False when no paired device speaks the control protocol — nothing to drive.
    var isPaired: Bool { device != nil }

    /// Called whenever `isAvailable` or `isConnected` may have moved, so the status item can
    /// insert, remove, or recolour itself. A plain callback rather than observation: the
    /// owner is AppKit, not a SwiftUI view.
    var onStateChange: (() -> Void)?



    // MARK: - Private

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var rxBuffer: [UInt8] = []
    private var disconnectObserver: IOBluetoothUserNotification?
    /// True while `openControlChannel` has work in flight. See the note there.
    private var isOpening = false

    /// Until when the link is taken as up on the strength of a positive event, whatever the
    /// `isConnected()` query says. The query lags several seconds behind an openConnection
    /// that has already returned success — the trace showed it still false through three
    /// deviceDidConnect callbacks — and the refresh that trusted it hid the menu bar item in
    /// the gap. Real evidence of a drop (deviceDidDisconnect) cancels the assertion early.
    private var linkAssertedUntil = Date.distantPast

    /// Covers the observed lag with slack; a wrong assertion self-corrects at the next poll.
    private static let linkAssertionGrace: TimeInterval = 10

    /// When a frame last arrived from the buds.
    ///
    /// This is the one unambiguous signal the app has. `isConnected()` under-reports, and
    /// `deviceDidDisconnect` fires on drops the data stream then carries on straight through
    /// — the trace showed battery and mode reports still landing while both the link and the
    /// channel were believed down. Bytes cannot arrive from earbuds that are not there.
    private var lastFrameAt = Date.distantPast

    /// How long the last frame counts for. The buds push status every few seconds unprompted,
    /// so a gap this long means they have genuinely gone rather than merely fallen quiet.
    private static let frameFreshness: TimeInterval = 8

    /// True while frames are arriving often enough to prove the buds are present.
    private var isStreamLive: Bool { Date().timeIntervalSince(lastFrameAt) < Self.frameFreshness }

    private func assertLinkUp() {
        isConnected = true
        didFailUserConnect = false
        linkAssertedUntil = Date().addingTimeInterval(Self.linkAssertionGrace)
    }
    private var pollTimer: Timer?
    private var ticks = 0

    override init() {
        super.init()
        if let initial = Self.discoverDevice() {
            device = initial
            deviceInfo.bluetoothAddress = initial.addressString ?? ""
            deviceInfo.modelName = initial.nameOrAddress ?? Self.fallbackName
        }
        syncName()

        // Fires for *any* device connecting; we filter to ours or auto-switch to supported.
        IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:)))

        refreshConnectionState()

        // Two jobs at two rates. Re-reading the link is a local query, so it runs often and
        // keeps `isConnected` honest no matter which notification was missed. Actually
        // reaching for the buds pages the radio, so that only happens every tenth tick.
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pollInterval, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            self.refreshConnectionState()
            self.ticks += 1
            if self.isControlChannelOpen && self.ticks % 3 == 0 {
                self.queryBattery()
            }
            if self.ticks % Self.ticksPerConnectAttempt == 0 { self.attemptAutoConnect() }
        }
        pollTimer?.tolerance = Self.pollInterval / 2   // no deadline worth a forced wakeup
        attemptAutoConnect()
    }

    /// How often the link state is re-read. `isConnected()` is a local lookup, not a radio
    /// round trip, so this can be brisk — it sets how fast the menu bar item reacts to a
    /// case being shut.
    private static let pollInterval: TimeInterval = 2

    /// Connect attempts are the expensive part — a shut case answers with a page timeout —
    /// so they run every tenth poll, i.e. every 20s.
    /// ponytail: fixed interval, not a backoff. Tune these two before adding one.
    private static let ticksPerConnectAttempt = 10

    private func attemptAutoConnect() {
        // Pairing or device switching can happen while we are running.
        if let bestDevice = Self.discoverDevice(), bestDevice.addressString != device?.addressString {
            if device == nil || !(device?.isConnected() ?? false) {
                switchDevice(to: bestDevice)
            }
        } else if device == nil, let bestDevice = Self.discoverDevice() {
            switchDevice(to: bestDevice)
        }
        guard !isConnected, !isSwitchedOff, !isBusy else { return }
        connect(auto: true)
    }

    /// Checks if a device is a candidate earbud based on SDP services or vendor name heuristics.
    static func isCandidateDevice(_ device: IOBluetoothDevice) -> Bool {
        let uuid = IOBluetoothSDPUUID(bytes: controlServiceUUID, length: 16)
        if device.getServiceRecord(for: uuid) != nil {
            return true
        }
        if let services = device.services as? [IOBluetoothSDPServiceRecord] {
            for service in services {
                if let sName = service.getServiceName(), sName.localizedCaseInsensitiveContains("oppointeraction") {
                    return true
                }
            }
        }
        let name = (device.nameOrAddress ?? "").lowercased()
        let keywords = ["realme", "oppo", "oneplus", "enco", "buds"]
        return keywords.contains { name.contains($0) }
    }

    /// All paired candidate devices on this Mac.
    static func pairedCandidateDevices() -> [IOBluetoothDevice] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }
        let uuid = IOBluetoothSDPUUID(bytes: controlServiceUUID, length: 16)
        return paired.filter { dev in
            dev.getServiceRecord(for: uuid) != nil || isCandidateDevice(dev)
        }
    }

    /// Picks the best paired device, prioritizing active/connected earbuds.
    ///
    /// Matching on the service rather than on a hardcoded address means any earbuds
    /// speaking this protocol work, and no one's Bluetooth address ends up in the source.
    /// `BUDSBAR_ADDRESS` forces a specific one when several are paired.
    private static func discoverDevice() -> IOBluetoothDevice? {
        if let forced = ProcessInfo.processInfo.environment["BUDSBAR_ADDRESS"] {
            return IOBluetoothDevice(addressString: forced)
        }
        let candidates = pairedCandidateDevices()
        if candidates.isEmpty { return nil }

        let uuid = IOBluetoothSDPUUID(bytes: controlServiceUUID, length: 16)

        // 1. Prefer currently connected devices with the control SDP record
        if let connWithSDP = candidates.first(where: { $0.isConnected() && $0.getServiceRecord(for: uuid) != nil }) {
            return connWithSDP
        }

        // 2. Any currently connected candidate device
        if let connCandidate = candidates.first(where: { $0.isConnected() }) {
            return connCandidate
        }

        // 3. Paired device with cached SDP record
        if let withSDP = candidates.first(where: { $0.getServiceRecord(for: uuid) != nil }) {
            return withSDP
        }

        // 4. Fallback to first candidate device
        return candidates.first
    }

    /// Called at app termination. Releasing the RFCOMM channel matters: macOS grants one
    /// per device, and a channel left to the OS reaper can refuse the next launch its open.
    func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        testTimer?.invalidate()
        testTimer = nil
        disconnectObserver?.unregister()
        disconnectObserver = nil
        closeControlChannel()
    }

    func connect() {
        connect(auto: false)
    }

    func connect(auto: Bool) {
        guard !isBusy, let device else { return }
        isAutoConnecting = auto
        // Intent is cleared straight away — the user asked for on, so the auto-connect poll
        // must be free to keep retrying. What holds the menu bar item in place across the
        // attempt is `isBusy` being part of `isAvailable`, not this flag.
        isSwitchedOff = false
        isBusy = true
        // Background retries neither surface errors nor erase one the user is reading.
        if !auto { lastError = nil }
        onStateChange?()
        // openConnection blocks until the baseband link is up or times out.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = device.openConnection()
            DispatchQueue.main.async {
                self.isBusy = false
                self.isAutoConnecting = false
                if result == kIOReturnSuccess { self.assertLinkUp() }
                // A failed background attempt is the normal state of a shut case, not an
                // error to display when the item next appears. A failed USER attempt is
                // different: with `isSwitchedOff` already cleared and `isBusy` ending here,
                // every availability term would be false and the item would vanish out from
                // under the toggle the user just flipped. `didFailUserConnect` keeps the item
                // and shows the error while leaving the poll free to retry — parking it in
                // `isSwitchedOff` instead also switched the retry off, so one slow page left
                // the app stuck disconnected until the toggle was used again.
                if result != kIOReturnSuccess, !auto {
                    self.lastError = Self.describe(result)
                    self.didFailUserConnect = true
                }
                // Refresh on both outcomes: a failed attempt still ends `isBusy`, and the
                // status item has to be told, or it sits stale until the next poll.
                self.refreshConnectionState()
            }
        }
    }

    func disconnect() {
        guard !isBusy, let device else { return }
        // The user asked for down — an earlier up-assertion must not outvote them while
        // closeConnection completes.
        linkAssertedUntil = .distantPast
        // Keeps the menu bar item present so the toggle can be switched back on, and stops
        // the auto-connect poll from undoing this a few seconds later.
        isSwitchedOff = true
        // Whatever arrived before this moment no longer counts as evidence of a live link.
        lastFrameAt = .distantPast
        didFailUserConnect = false
        onStateChange?()
        isBusy = true
        closeControlChannel()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = device.closeConnection()
            DispatchQueue.main.async {
                self.isBusy = false
                if result != kIOReturnSuccess { self.lastError = Self.describe(result) }
                self.refreshConnectionState()
            }
        }
    }

    // MARK: - Connection tracking

    /// The one place the disconnect observer is written. Both `deviceDidConnect` and
    /// `refreshConnectionState` need to register it, and assigning over a live registration
    /// leaks it still armed — a later disconnect then fires every orphaned observer too.
    private func armDisconnectObserver(for device: IOBluetoothDevice) {
        disconnectObserver?.unregister()
        disconnectObserver = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDidDisconnect(_:device:)))
    }

    @objc private func deviceDidConnect(_ notification: IOBluetoothUserNotification, device connected: IOBluetoothDevice) {
        if connected.addressString == device?.addressString {
            // Re-register per connection; the disconnect notification is one-shot.
            armDisconnectObserver(for: connected)
            DispatchQueue.main.async {
                // A link coming back after a switch-off is macOS re-establishing audio for an
                // earbud that is still being worn, not the user asking for the buds back. It is
                // not evidence of intent, so it does not clear `isSwitchedOff` — nor is there any
                // point asserting a link the app has been told to ignore.
                guard !self.isSwitchedOff else { return }
                self.assertLinkUp()
                // Re-read the display name: a new link is the natural moment to notice a rename.
                self.hasReadDisplayName = false
                self.refreshConnectionState()
            }
            return
        }

        // A new or different device connected! Check if it is a candidate/supported earbud.
        guard Self.isCandidateDevice(connected) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let uuid = IOBluetoothSDPUUID(bytes: Self.controlServiceUUID, length: 16)
            if connected.getServiceRecord(for: uuid) == nil {
                connected.performSDPQuery(nil)
                for _ in 0..<20 {
                    if connected.getServiceRecord(for: uuid) != nil { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            DispatchQueue.main.async {
                FileHandle.standardError.write(Data(
                    "Detected new device connect: \(connected.nameOrAddress ?? connected.addressString ?? "")\n".utf8))
                self.switchDevice(to: connected)
            }
        }
    }

    @objc private func deviceDidDisconnect(_ notification: IOBluetoothUserNotification, device disconnected: IOBluetoothDevice) {
        // Fired means spent — it is one-shot — so nil without unregister is correct here.
        disconnectObserver = nil
        DispatchQueue.main.async {
            self.linkAssertedUntil = .distantPast   // a real drop beats any grace window
            self.closeControlChannel()
            self.refreshConnectionState()
        }
    }

    /// Dynamically switches active device tracking to a new Bluetooth device.
    func switchDevice(to newDevice: IOBluetoothDevice) {
        if device?.addressString == newDevice.addressString && isControlChannelOpen {
            return
        }
        disconnectObserver?.unregister()
        disconnectObserver = nil
        closeControlChannel()

        device = newDevice
        hasReadDisplayName = false
        name = newDevice.nameOrAddress ?? Self.fallbackName
        deviceInfo.bluetoothAddress = newDevice.addressString ?? ""
        deviceInfo.modelName = name
        armDisconnectObserver(for: newDevice)

        isSwitchedOff = false
        didFailUserConnect = false
        syncName()

        if newDevice.isConnected() {
            assertLinkUp()
            openControlChannel()
        }
        refreshConnectionState()
        onStateChange?()
    }

    var availableDevices: [DeviceEntry] {
        Self.pairedCandidateDevices().map { dev in
            DeviceEntry(
                name: dev.nameOrAddress ?? "Earbuds",
                address: dev.addressString ?? "",
                isConnected: dev.isConnected()
            )
        }
    }

    func selectDevice(address: String) {
        if let target = Self.pairedCandidateDevices().first(where: { $0.addressString == address }) {
            switchDevice(to: target)
        }
    }

    func scanForDevices() {
        if let best = Self.discoverDevice() {
            switchDevice(to: best)
        } else {
            refreshConnectionState()
        }
    }

    /// Mirrors the name macOS shows in the Bluetooth settings.
    ///
    /// That is not `IOBluetoothDevice.name`, which reports the name the earbuds advertise
    /// over the air — renaming a device in Bluetooth settings does not change what the
    /// hardware calls itself, so the two drift apart (here: "Realme Buds" on screen,
    /// "realme Buds T500 Pro" over the air). Only the Bluetooth daemon holds the display
    /// name; it is in no readable preference file or IORegistry entry, and
    /// `system_profiler` is the one interface that reports it.
    ///
    /// Spawning a process is far too slow for the 2s poll that calls this, so the lookup
    /// runs once in the background and is repeated only when a new link comes up — which
    /// is also when a rename would realistically be noticed. The advertised name stands in
    /// meanwhile, and the hardcoded default only shows before either has answered.
    private func syncName() {
        if name == Self.fallbackName, let advertised = device?.name, !advertised.isEmpty {
            name = advertised
            deviceInfo.modelName = advertised
        }

        guard !hasReadDisplayName else { return }
        hasReadDisplayName = true
        guard let address = device?.addressString else { return }
        deviceInfo.bluetoothAddress = address
        DispatchQueue.global(qos: .utility).async {
            guard let displayName = Self.displayNameFromSystemProfiler(address: address)
            else { return }
            DispatchQueue.main.async {
                if self.name != displayName {
                    self.name = displayName
                    self.deviceInfo.modelName = displayName
                    self.onStateChange?()
                }
            }
        }
    }

    /// Reads the name Bluetooth settings shows. Each device is a single-pair dictionary
    /// keyed by its display name, so the key is the value we want and the address inside
    /// identifies which entry is ours.
    private static func displayNameFromSystemProfiler(address: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Drain before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }

        let wanted = address.replacingOccurrences(of: "-", with: ":").uppercased()
        for section in sections {
            // Look in both lists so the name is right even when the buds are away.
            for listKey in ["device_connected", "device_not_connected"] {
                guard let list = section[listKey] as? [[String: Any]] else { continue }
                for entry in list {
                    for (displayName, raw) in entry {
                        guard let info = raw as? [String: Any],
                              let addr = info["device_address"] as? String,
                              addr.uppercased() == wanted
                        else { continue }
                        return displayName
                    }
                }
            }
        }
        return nil
    }

    func refreshConnectionState() {
        syncName()
        // A live stream outranks everything else. `isConnected()` under-reports badly — it
        // goes false while the headset link is plainly still up, because the audio side holds
        // its own reference to a device this process has stopped connecting to — and the
        // assertion grace only papered over that for its ten seconds. Once it lapsed the
        // toggle flipped itself off, auto-connect asserted the link up again, and the two took
        // turns forever. The remaining terms are for the window before the first frame lands.
        //
        // A switch-off beats all of it. Frames keep arriving for a while after
        // `closeConnection` — believing them would put the app straight back into the loop
        // under a new name.
        let connected = !isSwitchedOff
            && (isStreamLive
                || isControlChannelOpen
                || (device?.isConnected() ?? false)
                || Date() < linkAssertedUntil)
        if connected != isConnected {
            FileHandle.standardError.write(Data((
                "LINK connected=\(connected) stream=\(isStreamLive) "
                + "channel=\(isControlChannelOpen) "
                + "available=\(connected || isSwitchedOff)\n").utf8))
        }
        isConnected = connected
        // `isSwitchedOff` is deliberately not touched here. It is user intent, and this
        // method is a state re-read that the poll calls every 2s — clearing the flag on
        // `connected` raced the poll against closeConnection(): the tick landing before the
        // link finished dropping saw connected=true, wiped the just-set flag, and the item
        // vanished once the drop completed. Intent is written only by connect()/disconnect()
        // and by deviceDidConnect (a genuine new link means the buds are on and in use).
        defer { onStateChange?() }
        if connected {
            // The connect notification only fires for connections made while we are running,
            // so buds already connected at launch would never get a disconnect observer —
            // and shutting the case would go unnoticed, leaving the menu bar item on screen.
            if disconnectObserver == nil, let device {
                armDisconnectObserver(for: device)
            }
            openControlChannel()
        } else {
            battery = BatteryState()
            placement = PlacementState()
            mode = nil
            ancLevel = nil
        }
    }

    // MARK: - Vendor control channel

    private func openControlChannel() {
        // `channel` is not assigned until the async work below finishes, so it cannot on its
        // own tell a second caller that an open is already under way. Without `isOpening`,
        // reopening the panel during those few seconds starts a competing SDP query and a
        // second openRFCOMMChannelAsync, which collide — and every command sent meanwhile is
        // dropped by `send`, which reads as the whole app lagging.
        guard channel == nil, !isOpening, let device else { return }
        isOpening = true

        DispatchQueue.global(qos: .userInitiated).async {
            // SDP-resolve the channel rather than hardcoding 15, so a firmware
            // renumber can't silently point us at a different service. The query has to run
            // in this process at least once or the channel open never completes.
            device.performSDPQuery(nil)

            // Poll instead of sleeping a flat two seconds: the record usually resolves in
            // well under that, and the wait used to be paid in full on every connect.
            let uuid = IOBluetoothSDPUUID(bytes: Self.controlServiceUUID, length: 16)
            var record: IOBluetoothSDPServiceRecord?
            for _ in 0..<40 {
                record = device.getServiceRecord(for: uuid)
                if record != nil { break }
                Thread.sleep(forTimeInterval: 0.05)
            }

            var channelID: BluetoothRFCOMMChannelID = 0
            guard let record else {
                DispatchQueue.main.async {
                    self.isOpening = false
                    self.lastError = "control service not found"
                }
                return
            }
            guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
                DispatchQueue.main.async {
                    self.isOpening = false
                    self.lastError = "control service has no RFCOMM channel"
                }
                return
            }

            DispatchQueue.main.async {
                defer { self.isOpening = false }
                var opened: IOBluetoothRFCOMMChannel?
                let result = device.openRFCOMMChannelAsync(
                    &opened, withChannelID: channelID, delegate: self)
                if result == kIOReturnSuccess {
                    self.channel = opened
                } else {
                    // Most likely another host already holds the control channel.
                    self.lastError = "control channel busy (\(Self.describe(result)))"
                }
            }
        }
    }

    private func closeControlChannel() {
        channel?.close()
        channel = nil
        rxBuffer.removeAll()
        isControlChannelOpen = false
    }

    // MARK: - Noise control

    func set(mode requested: NoiseMode) {
        // Switching to ANC has to name a level, since the level *is* the mode byte. Reusing
        // the level the buds last reported is what makes the button a no-op for anyone who
        // has already chosen one on the phone; `encodeSetNoiseMode` falls back to Max when
        // we have never seen a level (fresh launch, or the buds are on Smart).
        let level = requested == .noiseCancellation ? (ancLevel ?? .max) : ancLevel
        if send(BudsProtocol.encodeSetNoiseMode(requested, level: level)) {
            self.mode = requested
            if requested == .noiseCancellation && self.ancLevel == nil {
                self.ancLevel = .max
            }
            UserDefaults.standard.set(requested.wire, forKey: "lastNoiseMode")
            if let level {
                UserDefaults.standard.set(level.wire, forKey: "lastAncLevel")
            }
            if Self.isTracing {
                FileHandle.standardError.write(Data("MODE set to \(requested.label)\n".utf8))
            }
        }
    }

    /// Updates ANC level and switches mode to noise cancellation.
    func set(ancLevel requested: ANCLevel) {
        if send(BudsProtocol.encodeSetNoiseMode(.noiseCancellation, level: requested)) {
            self.mode = .noiseCancellation
            self.ancLevel = requested
            UserDefaults.standard.set(NoiseMode.noiseCancellation.wire, forKey: "lastNoiseMode")
            UserDefaults.standard.set(requested.wire, forKey: "lastAncLevel")
            if Self.isTracing {
                FileHandle.standardError.write(Data("LEVEL set to \(requested.label)\n".utf8))
            }
        }
    }

    @discardableResult
    private func send(_ packet: [UInt8]) -> Bool {
        guard let channel, isControlChannelOpen else { return false }
        if Self.isTracing {
            FileHandle.standardError.write(Data("TX \(BudsProtocol.hex(packet))\n".utf8))
        }
        var bytes = packet
        let result = bytes.withUnsafeMutableBytes { raw in
            channel.writeAsync(raw.baseAddress, length: UInt16(raw.count), refcon: nil)
        }
        if result != kIOReturnSuccess {
            lastError = "write failed: \(Self.describe(result))"
            return false
        }
        return true
    }

    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.name = trimmed
        UserDefaults.standard.set(trimmed, forKey: "customBudsName")
        onStateChange?()
    }

    func forgetDevice() {
        disconnect()
        device = nil
        onStateChange?()
    }



    func queryBattery() {
        if let standard = StandardBluetoothBatteryReader.shared.readBattery(from: device) {
            if battery.left == nil { battery.left = standard }
            if battery.right == nil { battery.right = standard }
        }
        guard isControlChannelOpen else { return }
        send(BudsProtocol.encodeBatteryQuery())
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else {
            lastError = "control channel open failed (\(Self.describe(error)))"
            self.channel = nil
            return
        }
        isControlChannelOpen = true
        lastError = nil
        if mode == nil, let savedWire = UserDefaults.standard.object(forKey: "lastNoiseMode") as? UInt8,
           let savedMode = NoiseMode(wire: savedWire) {
            mode = savedMode
        }
        if ancLevel == nil, let savedWire = UserDefaults.standard.object(forKey: "lastAncLevel") as? UInt8,
           let savedLevel = ANCLevel(wire: savedWire) {
            ancLevel = savedLevel
        }
        if battery.enclosure == nil,
           let savedCase = UserDefaults.standard.object(forKey: "lastCaseBattery") as? Int {
            battery.enclosure = savedCase
        }
        if Self.isTracing {
            FileHandle.standardError.write(Data("CHANNEL open complete\n".utf8))
        }
        if ProcessInfo.processInfo.environment["BUDSBAR_TEST"] != nil {
            // Give the handshake sent below time to land first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.startModeTest() }
        }
        for packet in BudsProtocol.handshake() {
            send(packet)
        }
        // Poll battery after the handshake has landed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.queryBattery()
        }
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let chunk = Array(UnsafeBufferPointer(
            start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength))

        // The buds go on talking for a while after a switch-off, and acting on that would
        // walk the app back to connected against the user's wishes. Drop it on the floor,
        // buffer included, so nothing is half-parsed when the toggle comes back on.
        guard !isSwitchedOff else {
            rxBuffer.removeAll()
            return
        }

        // Data is the proof the channel is alive, whatever the link bookkeeping believes. A
        // spurious deviceDidDisconnect tears the channel down on paper while the real one
        // keeps delivering; without this the app sat deaf behind that teardown, showing
        // Disconnected and a dead noise-control card while battery reports rolled in.
        lastFrameAt = Date()
        if !isControlChannelOpen {
            isControlChannelOpen = true
            self.channel = channel
            refreshConnectionState()
        }

        rxBuffer.append(contentsOf: chunk)
        // Raw trace, for decoding the payloads that are still unknown. Opt-in: the buds
        // push status every few seconds, so a shipped build would spew continuously.
        if Self.isTracing {
            FileHandle.standardError.write(Data("RX \(BudsProtocol.hex(chunk))\n".utf8))
        }

        // RFCOMM delivers arbitrary chunks; frames split across callbacks.
        let frames = BudsProtocol.drainFrames(from: &rxBuffer)
        for frame in frames {
            // Full frame trace: logs every opcode the T310 sends, not just those
            // interpret() already recognises. Essential for mapping a new device.
            if Self.isTracing {
                let line = "FRAME opcode=\(String(format: "%04x", frame.opcode)) "
                    + "seq=\(frame.sequence) "
                    + "payload=\(BudsProtocol.hex(frame.payload))\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            if frame.opcode == 0x0081 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.queryBattery()
                }
            }
            apply(frame)
        }
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        closeControlChannel()
    }

    private func apply(_ frame: BudsProtocol.Frame) {
        if frame.opcode == BudsProtocol.opcodeNoiseModeAck {
            if Self.isTracing {
                let status = frame.payload.first.map { String(format: "%02x", $0) } ?? "00"
                FileHandle.standardError.write(Data("MODE ACK received (status=\(status))\n".utf8))
            }
        }
        if frame.opcode == BudsProtocol.opcodeBatteryReport || frame.opcode == BudsProtocol.opcodeStatusReport {
            let pairs = BudsProtocol.extractBatteryPairs(from: frame.payload)
            
            var leftValue: UInt8?
            var rightValue: UInt8?
            var caseValue: UInt8?
            
            for (id, value) in pairs {
                switch id {
                case 1: leftValue = value
                case 2: rightValue = value
                case 3: caseValue = value
                default: break
                }
            }
            
            // Case charging is indicated by bit 7 on slot 3
            if let cv = caseValue {
                battery.isEnclosureCharging = (cv & 0x80) != 0
            }
            
            // The case is actively awake and reporting if slot 3 is present and non-zero
            let isCaseLive = caseValue.map { ($0 & 0x7f) > 0 } ?? false
            let earbudPairs = pairs.filter { $0.0 == 1 || $0.0 == 2 }
            
            // Default: reset charging flags and assume in use
            battery.isLeftCharging = false
            battery.isRightCharging = false
            placement.left = .inUse
            placement.right = .inUse
            
            if isCaseLive {
                // When an active case is reporting via the pins, determine which bud is in the case:
                // In BES / TWS protocol, the earbud in the user's ear is the Master (earbudPairs[0]),
                // and the earbud docked inside the charging case is the Slave (earbudPairs[1]).
                if earbudPairs.count >= 2 {
                    let dockedSlot = earbudPairs[1].0
                    if dockedSlot == 1 {
                        battery.isLeftCharging = true
                        placement.left = .inCase
                    } else if dockedSlot == 2 {
                        battery.isRightCharging = true
                        placement.right = .inCase
                    }
                } else if earbudPairs.count == 1 {
                    let singleSlot = earbudPairs[0].0
                    if singleSlot == 1 {
                        battery.isLeftCharging = true
                        placement.left = .inCase
                    } else if singleSlot == 2 {
                        battery.isRightCharging = true
                        placement.right = .inCase
                    }
                }
            }
            
            // Explicit bit 7 override if present on any earbud
            if let lv = leftValue, (lv & 0x80) != 0 {
                battery.isLeftCharging = true
                placement.left = .inCase
            }
            if let rv = rightValue, (rv & 0x80) != 0 {
                battery.isRightCharging = true
                placement.right = .inCase
            }
        }
        for update in BudsProtocol.interpret(frame) {
            switch update {
            case .noiseMode(let value):
                if mode != value {
                    // Not logging `value.wire` — for ANC that is the default level's byte,
                    // not the one that arrived. The LEVEL line below carries that detail.
                    FileHandle.standardError.write(Data("MODE reported \(value.label)\n".utf8))
                }
                mode = value
                UserDefaults.standard.set(value.wire, forKey: "lastNoiseMode")
            case .ancLevel(let value):
                if ancLevel != value {
                    FileHandle.standardError.write(
                        Data("LEVEL reported \(value?.label ?? "unknown (Smart)")\n".utf8))
                }
                ancLevel = value
                if let value {
                    UserDefaults.standard.set(value.wire, forKey: "lastAncLevel")
                }
            case .battery(let slot, let level):
                if Self.isTracing {
                    FileHandle.standardError.write(
                        Data("BATTERY \(slot) \(level.map(String.init) ?? "unknown")%\n".utf8))
                }
                // Assigned, not merged: nil here means the buds reported the slot as
                // unknown, and a slot they did not mention produces no update at all.
                switch slot {
                case .left: battery.left = level
                case .right: battery.right = level
                case .enclosure:
                    if let level {
                        battery.enclosure = level
                        UserDefaults.standard.set(level, forKey: "lastCaseBattery")
                    } else if battery.enclosure == nil,
                              let saved = UserDefaults.standard.object(forKey: "lastCaseBattery") as? Int {
                        battery.enclosure = saved
                    }
                }

            case .placement(let slot, let where_):
                if slot == .left {
                    guard placement.left != where_ else { break }
                    FileHandle.standardError.write(Data("PLACEMENT left \(where_)\n".utf8))
                    placement.left = where_
                } else if slot == .right {
                    guard placement.right != where_ else { break }
                    FileHandle.standardError.write(Data("PLACEMENT right \(where_)\n".utf8))
                    placement.right = where_
                }
                // Only on the move into the case, not on every report of it. A bud put away
                // drops out of the battery report entirely, and an absent slot keeps its last
                // reading — so the reading it had while in use would stand on the panel
                // indefinitely. Clearing it once is enough: an awake case goes on reporting
                // the bud inside it, and the next report fills the value back in within
                // seconds. A case that has gone to sleep reports nothing, which is when the
                // stale number used to sit there, and now the cell honestly reads unknown.
                // When placed in the case, keep the last known battery level so the panel
                // continues showing the battery percentage and charging state.
            }
        }
    }

    // MARK: - Mode cycle test

    /// Drives every mode and every ANC level in turn so the commands can be verified end to
    /// end against the notifications the buds send back. Runs only under BUDSBAR_TEST=1.
    private var testQueue: [(label: String, send: () -> Void)] = []
    private var testTimer: Timer?

    private func startModeTest() {
        guard isControlChannelOpen else { return }
        testQueue = ANCLevel.allCases.map { level in
            ("ANC \(level.label), value \(level.wire)", { [weak self] in self?.set(ancLevel: level) })
        } + [
            ("Transparency", { [weak self] in self?.set(mode: .transparency) }),
            ("Off", { [weak self] in self?.set(mode: .off) }),
        ]
        testLog("cycling modes, 3s apart")
        testTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let next = self.testQueue.first else {
                self.testLog("mode cycle complete")
                self.testTimer?.invalidate()
                self.testTimer = nil
                return
            }
            self.testQueue.removeFirst()
            self.testLog("commanding \(next.label)")
            next.send()
        }
    }

    private func testLog(_ message: String) {
        FileHandle.standardError.write(Data("TEST \(message)\n".utf8))
    }

    // MARK: - Errors

    private static func describe(_ code: IOReturn) -> String {
        switch code {
        case kIOReturnSuccess: return "ok"
        case kIOReturnTimeout: return "timed out — buds asleep, in the case, or out of range"
        case kIOReturnNoDevice: return "device not found"
        case kIOReturnBusy: return "busy"
        case kIOReturnExclusiveAccess: return "already in use by another app"
        case kIOReturnNotOpen: return "not open"
        default: return "IOReturn \(code)"
        }
    }
}
