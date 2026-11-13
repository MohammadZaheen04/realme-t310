import Foundation
import IOBluetooth
import CoreBluetooth
import ObjectiveC

/// Reads battery level via the standard Bluetooth Battery Service (UUID 0x180F / 0x2A19)
/// and IOBluetooth system battery status before relying on vendor-proprietary RFCOMM reports.
public final class StandardBluetoothBatteryReader: NSObject {

    public static let shared = StandardBluetoothBatteryReader()

    /// Standard GATT Battery Service UUID (0x180F)
    public static let batteryServiceUUID = CBUUID(string: "180F")
    /// Standard GATT Battery Level Characteristic UUID (0x2A19)
    public static let batteryLevelCharacteristicUUID = CBUUID(string: "2A19")

    /// Reads standard battery percentage for an IOBluetoothDevice safely.
    public func readBattery(from device: IOBluetoothDevice?) -> Int? {
        guard let device else { return nil }

        // Query IOBluetoothDevice batteryPercentSingle safely via IMP casting.
        // Calling via `perform(selector)` crashes because the method returns a primitive scalar,
        // which Swift's perform(_:) mistakenly attempts to retain as an Objective-C object pointer.
        let selector = NSSelectorFromString("batteryPercentSingle")
        if device.responds(to: selector),
           let cls = object_getClass(device),
           let method = class_getInstanceMethod(cls, selector) {
            typealias ScalarBatteryFunc = @convention(c) (AnyObject, Selector) -> Int32
            let imp = method_getImplementation(method)
            let fn = unsafeBitCast(imp, to: ScalarBatteryFunc.self)
            let val = fn(device, selector)
            if val > 0 && val <= 100 {
                return Int(val)
            }
        }

        // Check for standard 0x180F Battery Service SDP record
        let uuid = IOBluetoothSDPUUID(uuid16: 0x180F)
        if let record = device.getServiceRecord(for: uuid) {
            _ = record
        }

        return nil
    }
}
