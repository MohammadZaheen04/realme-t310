import Foundation

/// Wire format for the `oppointeraction` RFCOMM channel on realme/OPPO earbuds.
///
/// Pure functions over bytes — no I/O — so `selfCheck()` can exercise them against
/// recorded traffic without the hardware present.
///
///     aa <len> <b2> <b3> <opcode:u16be> <seq> <payloadLen:u16le> <payload…>
///
/// `len` counts every byte after itself, so a frame is `len + 2` bytes long. There is no
/// trailing checksum — the length accounts for the payload exactly.
///
/// The payload is a tagged list: `<type> <count>` followed by `count` (id, value) pairs.
public enum BudsProtocol {

    public static let sync: UInt8 = 0xaa
    /// Unsolicited device status report.
    public static let opcodeStatusReport: UInt16 = 0x0402
    /// Battery report opcode in OPOv1 standard (Category 0x06, Subcommand 0x81).
    public static let opcodeBatteryReport: UInt16 = 0x0681
    /// Noise mode command acknowledgment opcode in OPOv1 standard (Category 0x04, Subcommand 0x84).
    public static let opcodeNoiseModeAck: UInt16 = 0x0484

    public struct Frame {
        public var opcode: UInt16
        public var sequence: UInt8
        public var payload: [UInt8]
        public var raw: [UInt8]

        public init(opcode: UInt16, sequence: UInt8, payload: [UInt8], raw: [UInt8]) {
            self.opcode = opcode
            self.sequence = sequence
            self.payload = payload
            self.raw = raw
        }
    }

    public enum Update: Equatable {
        case noiseMode(NoiseMode)
        case ancLevel(ANCLevel?)
        case battery(BatterySlot, Int?)
        case placement(BatterySlot, BudsPlacement)
    }

    public enum BatterySlot: UInt8 {
        case left = 0x01
        case right = 0x02
        case enclosure = 0x03
    }

    public typealias BudPlacement = BudsPlacement

    // MARK: - Payload types

    private enum PayloadType: UInt8 {
        case battery = 0x01
        case placement = 0x02
        case noiseMode = 0x03
    }

    private static let noiseModeID: UInt8 = 0x01

    // MARK: - Sending Handshake & Status

    public static func handshake() -> [[UInt8]] { [encodeHello()] }

    public static func makeFrame(_ b2: UInt8, _ b3: UInt8, _ b4: UInt8, _ b5: UInt8,
                                 sequence: UInt8, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= 0xff - 7, "payload too long for a one-byte length")
        var frame: [UInt8] = [sync, 0, b2, b3, b4, b5, sequence,
                              UInt8(payload.count & 0xff), UInt8(payload.count >> 8)]
        frame += payload
        frame[1] = UInt8(frame.count - 2)
        return frame
    }

    public enum Category: UInt8 {
        case system = 0x00
        case status = 0x04
        case audio = 0x05
        case battery = 0x06
        case feature = 0x07
    }

    private enum SystemSubcommand: UInt8 {
        case hello = 0x01
    }

    private enum StatusSubcommand: UInt8 {
        case setNoiseMode = 0x04
    }

    private enum BatterySubcommand: UInt8 {
        case query = 0x01
    }

    // MARK: - Verified Working Encoders

    public static func encodeSetNoiseMode(_ mode: NoiseMode, level: ANCLevel? = nil) -> [UInt8] {
        let value = mode == .noiseCancellation ? (level ?? .strong).wire : mode.wire
        return makeFrame(0x00, 0x00, Category.status.rawValue, StatusSubcommand.setNoiseMode.rawValue,
                          sequence: nextSequence(),
                          payload: [0x01, 0x01, value])
    }

    public static func encodeHello() -> [UInt8] {
        makeFrame(0x00, 0x00, Category.system.rawValue, SystemSubcommand.hello.rawValue,
                  sequence: nextSequence(), payload: [])
    }

    public static func encodeBatteryQuery() -> [UInt8] {
        makeFrame(0x00, 0x00, Category.battery.rawValue, BatterySubcommand.query.rawValue,
                  sequence: nextSequence(), payload: [])
    }

    private static var sequenceCounter: UInt8 = 0

    public static func nextSequence() -> UInt8 {
        sequenceCounter &+= 1
        return sequenceCounter
    }

    // MARK: - Receiving & Parsing

    public static func drainFrames(from buffer: inout [UInt8]) -> [Frame] {
        var frames: [Frame] = []

        while true {
            guard let start = buffer.firstIndex(of: sync) else {
                buffer.removeAll()
                break
            }
            if start > 0 { buffer.removeFirst(start) }

            guard buffer.count >= 2 else { break }
            let total = Int(buffer[1]) + 2
            guard total >= 9 else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= total else { break }

            let raw = Array(buffer[0..<total])
            let payloadLength = Int(raw[7]) | Int(raw[8]) << 8
            if 9 + payloadLength == total {
                frames.append(Frame(
                    opcode: UInt16(raw[4]) << 8 | UInt16(raw[5]),
                    sequence: raw[6],
                    payload: Array(raw[9..<total]),
                    raw: raw))
                buffer.removeFirst(total)
            } else {
                buffer.removeFirst()
            }
        }

        return frames
    }

    public static func interpret(_ frame: Frame) -> [Update] {
        if frame.opcode == opcodeBatteryReport {
            return interpretBatteryReport(frame.payload, raw: frame.raw)
        }
        guard frame.opcode == opcodeStatusReport else { return [] }

        let payload = frame.payload
        guard payload.count >= 2, let type = PayloadType(rawValue: payload[0]) else { return [] }

        let count = Int(payload[1])
        var pairs: [(UInt8, UInt8)] = []
        var index = 2
        for _ in 0..<count {
            guard index + 1 < payload.count else { break }
            pairs.append((payload[index], payload[index + 1]))
            index += 2
        }

        switch type {
        case .battery:
            return pairs.compactMap { id, value in
                guard let slot = BatterySlot(rawValue: id) else { return nil }
                let percent = Int(value & 0x7f)
                return .battery(slot, percent == 0 ? nil : percent)
            }

        case .noiseMode:
            guard count == 1 else { return [] }

            for (id, value) in pairs where id == noiseModeID {
                guard let mode = NoiseMode(wire: value) else { return [] }
                guard mode == .noiseCancellation else { return [.noiseMode(mode)] }
                return [.noiseMode(mode), .ancLevel(ANCLevel(wire: value))]
            }
            return []

        case .placement:
            return pairs.compactMap { id, value in
                guard let slot = BatterySlot(rawValue: id),
                      let placement = BudsPlacement(rawValue: value)
                else { return nil }
                return .placement(slot, placement)
            }
        }
    }

    public static func extractBatteryPairs(from payload: [UInt8]) -> [(UInt8, UInt8)] {
        guard !payload.isEmpty else { return [] }
        var pairs: [(UInt8, UInt8)] = []
        if payload.count >= 2 {
            let count = Int(payload[1])
            if count > 0 && payload.count >= 2 + count * 2 {
                var index = 2
                for _ in 0..<count {
                    pairs.append((payload[index], payload[index + 1]))
                    index += 2
                }
            }
        }
        if pairs.isEmpty && payload.count >= 3 {
            let count = Int(payload[0])
            if count > 0 && count <= 4 && payload.count >= 1 + count * 2 {
                var index = 1
                for _ in 0..<count {
                    pairs.append((payload[index], payload[index + 1]))
                    index += 2
                }
            }
        }
        return pairs
    }

    public static func interpretBatteryReport(_ payload: [UInt8], raw: [UInt8] = []) -> [Update] {
        let pairs = extractBatteryPairs(from: payload)
        return pairs.compactMap { id, value in
            guard let slot = BatterySlot(rawValue: id) else { return nil }
            let percent = Int(value & 0x7f)
            return .battery(slot, percent == 0 ? nil : percent)
        }
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    // MARK: - Self check

    public static func selfCheck() {
        func bytes(_ string: String) -> [UInt8] {
            string.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        }

        var buffer = bytes("aa 0f 00 00 04 02 0c 08 00 01 03 01 64 02 64 03 50")
        var frames = drainFrames(from: &buffer)
        assert(frames.count == 1, "one battery frame")
        assert(buffer.isEmpty, "buffer fully consumed")
        assert(frames[0].opcode == opcodeStatusReport)
        assert(interpret(frames[0]) == [.battery(.left, 100), .battery(.right, 100),
                                        .battery(.enclosure, 80)])

        buffer = bytes("aa 0f 00 00 04 02 10 08 00 01 03 01 64 02 64 03 00")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]) == [.battery(.left, 100), .battery(.right, 100),
                                        .battery(.enclosure, nil)],
               "a sleeping case reads as unknown, and says so rather than staying silent")

        buffer = bytes("aa 0d 00 00 04 02 99 06 00 01 02 01 64 03 00")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]) == [.battery(.left, 100), .battery(.enclosure, nil)],
               "an absent slot is not the same as an unknown one")

        for (wire, expected) in [("01", NoiseMode.off), ("02", .transparency)] {
            buffer = bytes("aa 0b 00 00 04 02 9b 04 00 03 01 01 \(wire)")
            frames = drainFrames(from: &buffer)
            assert(interpret(frames[0]) == [.noiseMode(expected)], "wire \(wire)")
        }

        for (wire, expected) in [("04", ANCLevel.light),
                                 ("08", ANCLevel.strong),
                                 ("10", ANCLevel.medium)] {
            buffer = bytes("aa 0b 00 00 04 02 9b 04 00 03 01 01 \(wire)")
            frames = drainFrames(from: &buffer)
            assert(interpret(frames[0]) == [.noiseMode(.noiseCancellation), .ancLevel(expected)],
                   "ANC level wire \(wire)")
        }

        // Adaptive level (0x20)
        buffer = bytes("aa 0b 00 00 04 02 48 04 00 03 01 01 20")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]) == [.noiseMode(.noiseCancellation), .ancLevel(.adaptive)],
               "Adaptive reports ANC with adaptive level")

        buffer = bytes("aa 0b 00 00 04 02 48 04 00 03 04 01 10")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]).isEmpty, "Smart's effective-level echo is ignored")

        buffer = bytes("aa 0b 00 00 04 02 9b 04 00 03 01 01 01")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]) == [.noiseMode(.off)], "Off does not clear the level")

        buffer = bytes("aa 0b 00 00 04 02 1a 04 00 03 01 01 7f")
        frames = drainFrames(from: &buffer)
        assert(frames.count == 1 && buffer.isEmpty, "short frame")
        assert(interpret(frames[0]).isEmpty, "unknown mode value ignored")

        buffer = bytes("aa 0f 00 00 04 02 98 08 00 02 03 01 00 02 03 03 04")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]) == [.placement(.left, .inCase), .placement(.right, .inUse)],
               "0x02 block is placement, and carries no mode")

        buffer = bytes("aa 0f 00 00 04 02 a0 08 00 02 03 01 00 02 00 03 04")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]) == [.placement(.left, .inCase), .placement(.right, .inCase)],
               "both buds in the case")

        buffer = bytes("aa 0d 00 00 04 02 97 06 00 01 02 02 64 03 00")
        frames = drainFrames(from: &buffer)
        assert(interpret(frames[0]) == [.battery(.right, 100), .battery(.enclosure, nil)],
               "a bud in the case is absent from the battery report, not zero")

        var sent = encodeSetNoiseMode(.transparency)
        assert(sent == bytes("aa 0a 00 00 04 04 \(String(format: "%02x", sent[6])) 03 00 01 01 02"),
               "set frame layout: \(hex(sent))")
        frames = drainFrames(from: &sent)
        assert(frames.count == 1 && sent.isEmpty, "set frame parses as one frame")
        assert(frames[0].opcode == 0x0404, "set uses the set opcode, not the report one")
        assert(interpret(frames[0]).isEmpty, "a set frame is not a status update")

        assert(encodeSetNoiseMode(.noiseCancellation, level: .medium).last == 0x10, "set Medium")
        assert(encodeSetNoiseMode(.noiseCancellation, level: .light).last == 0x04, "set Light")
        assert(encodeSetNoiseMode(.noiseCancellation).last == ANCLevel.strong.wire, "ANC defaults to Strong")
        assert(encodeSetNoiseMode(.off, level: .light).last == 0x01, "level does not leak into Off")

        for level in ANCLevel.allCases {
            var command = encodeSetNoiseMode(.noiseCancellation, level: level)
            let value = command.last!
            command = bytes("aa 0b 00 00 04 02 9b 04 00 03 01 01 \(String(format: "%02x", value))")
            frames = drainFrames(from: &command)
            assert(interpret(frames[0]) == [.noiseMode(.noiseCancellation), .ancLevel(level)],
                   "\(level.label) round-trips")
        }

        buffer = bytes("aa 0b 00 00 04 02 1a 04 00 03 01 01 08")
             + bytes("aa 0f 00 00 04 02 0c 08 00 01 03 01 64 02 64 03 50")
        frames = drainFrames(from: &buffer)
        assert(frames.count == 2 && buffer.isEmpty, "coalesced frames")

        let whole = bytes("aa 0f 00 00 04 02 0c 08 00 01 03 01 64 02 64 03 50")
        buffer = Array(whole[0..<6])
        assert(drainFrames(from: &buffer).isEmpty, "partial frame withheld")
        buffer.append(contentsOf: whole[6...])
        frames = drainFrames(from: &buffer)
        assert(frames.count == 1 && buffer.isEmpty, "frame completed across reads")
        assert(interpret(frames[0]) == [.battery(.left, 100), .battery(.right, 100),
                                        .battery(.enclosure, 80)])

        buffer = bytes("ff ff") + whole
        frames = drainFrames(from: &buffer)
        assert(frames.count == 1 && buffer.isEmpty, "resynchronised past garbage")

        let batQuery = encodeBatteryQuery()
        assert(batQuery == bytes("aa 07 00 00 06 01 \(String(format: "%02x", batQuery[6])) 00 00"),
               "battery query frame layout")

        buffer = bytes("aa 0f 00 00 06 81 0b 08 00 00 03 02 32 01 14 03 00")
        frames = drainFrames(from: &buffer)
        assert(frames.count == 1 && frames[0].opcode == opcodeBatteryReport)
        assert(interpret(frames[0]) == [.battery(.right, 50), .battery(.left, 20), .battery(.enclosure, nil)],
               "T310 battery report decoding")

        buffer = bytes("aa 0f 00 00 06 81 1d 08 00 00 03 01 14 02 32 03 8a")
        frames = drainFrames(from: &buffer)
        assert(frames.count == 1 && frames[0].opcode == opcodeBatteryReport)
        assert(interpret(frames[0]) == [.battery(.left, 20), .battery(.right, 50), .battery(.enclosure, 10)],
               "T310 battery report decoding with charging case")

        buffer = bytes("aa 08 00 00 04 84 2c 01 00 00")
        frames = drainFrames(from: &buffer)
        assert(frames.count == 1 && frames[0].opcode == opcodeNoiseModeAck, "0x0484 ACK opcode parses")

        FileHandle.standardError.write(Data("BudsProtocol.selfCheck passed\n".utf8))
    }
}
