# Realme TWS Mac Controller

A macOS menu bar app for **realme / OPPO / OnePlus earbuds** that speak the OPOv1 control
protocol. Shows per-earbud and case battery, switches between ANC / Off / Transparency with
the three ANC strengths, and connects or disconnects the buds — none of which macOS exposes
on its own.

Developed against realme Buds T500 Pro. The buds are found by looking for the paired device
that advertises the control service, so no address is baked into the source and any earbuds
speaking this protocol should work; the mode *values*, though, were confirmed on the T500
Pro only and other models may number them differently (see [The protocol](#the-protocol)).

There is no macOS realme Link. To a Mac these are a plain A2DP/HFP headset: noise control
can only be changed by touching an earbud, and the system reports a single battery figure
instead of three. This app talks to the earbuds' vendor control protocol directly.

(The code, binary, and bundle identifier keep the original internal name **BudsBar** — the
identifier is fixed so the granted Bluetooth permission survives rebuilds.)

State is read back from the earbuds rather than assumed, so the panel and realme Link on a
phone agree with each other. Change the mode on the phone and the app follows within about
a second; change it in the app and the phone follows.

## Install

[![Download](https://img.shields.io/badge/Download-Realme%20TWS%20Mac%20Controller-blue?style=for-the-badge&logo=apple)](https://github.com/aniket-2308/Realme-TWS-Mac-Controller/releases/latest/download/Realme-TWS-Mac-Controller.zip)

Or paste this into Terminal — it downloads the latest release, installs it into
`/Applications`, and launches it:

```sh
curl -fsSL https://raw.githubusercontent.com/aniket-2308/Realme-TWS-Mac-Controller/main/install.sh | sh
```

The build is ad-hoc signed, not notarised. The script clears the quarantine flag for you;
if you download the zip by hand instead, macOS will refuse to open it until you run:

```sh
xattr -dr com.apple.quarantine "/Applications/Realme TWS Mac Controller.app"
```

The download needs no toolchain — the [requirements](#requirements) below apply to building
from source.

## Requirements

- macOS 26 or later (uses the Liquid Glass APIs)
- Swift 6.2+ toolchain — Command Line Tools are enough to compile
- An installed `Xcode.app`, for one file only: the SwiftUI macro plugin. It does **not**
  need to be selected with `xcode-select`. See [Building](#building).
- Earbuds already paired with the Mac and advertising the `oppointeraction` service

## Building

```sh
./build.sh            # release; pass `debug` for a debug build
open "Realme TWS Mac Controller.app"
```

Run the binary directly to see its log on stderr:

```sh
"./Realme TWS Mac Controller.app/Contents/MacOS/BudsBar"
```

Environment variables, all optional:

| Variable | Effect |
|---|---|
| `BUDSBAR_TRACE=1` | Hex-dump every frame received. Off by default — the buds push status every few seconds. |
| `BUDSBAR_TEST=1` | Command every mode and ANC level in turn and log what the buds report back. |
| `BUDSBAR_ADDRESS=aa-bb-…` | Force a specific device instead of auto-discovering, for when several paired devices speak the protocol. |

`build.sh` compiles with SwiftPM, assembles the `.app` bundle, and ad-hoc signs it. The
bundle identifier is fixed across rebuilds so the granted Bluetooth permission survives,
though re-signing may prompt once more.

### Why Xcode is needed to build

SwiftUI's `@State` and `@Bindable` are macros, and the Command Line Tools ship the SwiftUI
framework *without* its macro plugin — so every property wrapper fails to compile. The
manifest locates `libSwiftUIMacros.dylib` inside any `/Applications/Xcode*.app` and passes
it to the compiler. The plugin loads into the CLT compiler even when that Xcode's own
toolchain is too old to run on the current OS. Declaring it in `Package.swift` rather than
only in `build.sh` keeps SourceKit — and therefore editor diagnostics — working too.

## Layout

```
Package.swift                      SwiftPM manifest; also locates the SwiftUI macro plugin
build.sh                           build → .app bundle → ad-hoc codesign
Resources/Info.plist               LSUIElement, NSBluetoothAlwaysUsageDescription
Sources/BudsBar/
  App.swift                        NSStatusItem menu bar item and popover host
  BudsDeviceProtocol.swift         Universal controller protocol & observable models
  MockBudsDevice.swift             Fully interactive mock device for testing with fake data
  BudsManager.swift                Unified manager for real & mock device switching
  StandardBluetoothBatteryReader.swift Standard Bluetooth Battery Service (UUID 0x180F) reader
  Buds.swift                       IOBluetooth transport and live device implementation
  Protocol.swift                   OPOv1 frame encoding/decoding with marked TODOs for proprietary commands
  PanelView.swift                  The enhanced popover UI with collapsible cards
Tools/sniff.swift                  Read-only RFCOMM logger for sniffing commands
```

`Info.plist` needs `NSBluetoothAlwaysUsageDescription`; without it the Bluetooth
permission prompt never appears and RFCOMM fails silently. `LSUIElement` keeps the app out
of the Dock.

## The protocol

The buds expose several RFCOMM services over Bluetooth Classic. The one that matters is
`oppointeraction`, SDP UUID `0000079A-D102-11E1-9B23-00025B00A5A5` — **OPOv1**, the control
protocol shared across BBK Electronics brands (OPPO, OnePlus, realme). The app resolves the
channel by UUID at runtime rather than hardcoding a number, so a firmware renumber can't
silently point it at a different service.

### Frame format

```
aa  <len>  00 00  <cat>  <sub>  <seq>  <payload len: u16le>  <payload…>
```

`len` counts every byte after itself, so a frame is `len + 2` bytes. There is **no
checksum** — the length fields account for the payload exactly. A reply echoes the request's
`seq` and sets the high bit on `sub` (`0x04` → `0x84`). Payload byte 0 of a reply is a
status: `00` accepted, `01` rejected.

### Commands used

| Purpose | Frame |
|---|---|
| Hello | `aa 07 00 00 00 01 <seq> 00 00` |
| Off | `aa 0a 00 00 04 04 <seq> 03 00 01 01 01` |
| Transparency | `aa 0a 00 00 04 04 <seq> 03 00 01 01 02` |
| ANC, Mild | `aa 0a 00 00 04 04 <seq> 03 00 01 01 04` |
| ANC, Max | `aa 0a 00 00 04 04 <seq> 03 00 01 01 08` |
| ANC, Moderate | `aa 0a 00 00 04 04 <seq> 03 00 01 01 10` |

**The ANC and Off values are the reverse of the published OnePlus mapping.** On the T500
Pro `0x01` is Off. Taking the documented mapping at face value produced an app where those
two buttons did each other's job.

**There is no single "ANC" value — the strength is the mode byte.** realme Link's four
noise-cancellation sub-modes each get their own value, and they are not in strength order:

| Value | Mode |
|---|---|
| `01` | Off |
| `02` | Transparency |
| `04` | ANC, Mild |
| `08` | ANC, Max |
| `10` | ANC, Moderate |
| `20` | ANC, Smart |

Confirmed by running `Tools/sniff.swift` while tapping each level on the phone, with
single-tap runs for Mild and Max on their own to break the ambiguity — a multi-tap trace is
hard to read, because the buds also announce their *current* mode when the phone's app
opens, so the first event in a run belongs to the state before it, not to the first tap.

This is also why the earlier reading of `0x08` as "a second ANC variant (adaptive)" was
wrong, and why the ANC button used to command `0x04`: it was pinning the buds to Mild every
time. Smart (`0x20`) is decoded as ANC but deliberately has no level in this app; while it
is active the buds emit a second `03` block — count `4`, one pair — carrying the level Smart
has settled on, which the app ignores so the panel cannot show a level the phone is not.

### Notifications

The buds push status on category `04`, subcommand `02`, unprompted. The payload is a tagged
list — `<type> <count>` then `count` (id, value) pairs:

| Type | Meaning |
|---|---|
| `01` | Battery: id 1 = left, 2 = right, 3 = case, values in percent |
| `02` | Some other setting. Moves when the mode changes but is **not** the mode. Not decoded. |
| `03` | Noise mode: id 1, value as in the table above. Count is always 1 — a `03` block with count 4 is Smart reporting the level it picked, not a mode change. |

Three traps worth knowing, all of which cost real debugging time here:

- The mode lives in the **`03`** block, not `02`. The `02` block also moves when the mode
  changes, which makes it look like the mode until you command a value and watch which
  field actually follows.
- Rejection error codes are **not** a signal about your payload. The same bytes return
  different codes depending on position in a run of requests, so they cannot be used to
  hill-climb toward a correct payload shape.
- Do not trust another device's value mapping. The frame *format* carried over from the
  OnePlus documentation intact, but the ANC and Off values did not.

## Capturing the Bluetooth Protocol from the realme Link App

This project puts all proprietary realme commands behind `BudsProtocol` and `BudsDeviceProtocol`. While ANC and Noise Mode commands are implemented and verified, other commands (Equalizer presets, custom 5-band EQ, touch gestures, low-latency mode, and find my buds) have clearly marked `// TODO: Paste captured packet bytes here` sections in [Protocol.swift](file:///Users/mohammadzaheen/Documents/Realme-TWS-Mac-Controller-source/Sources/BudsBar/Protocol.swift).

Here is how to capture the exact packet bytes from the official realme Link mobile app:

### Method 1: Android Bluetooth HCI Snoop Log (Recommended)

This is the most reliable way to capture raw packet exchanges between the realme Link app and your earbuds.

1. **Enable Developer Options on Android**:
   - Go to **Settings** → **About Phone** → tap **Build Number** 7 times.
2. **Enable Bluetooth HCI Snoop Logging**:
   - Go to **Settings** → **System** → **Developer Options**.
   - Toggle **Enable Bluetooth HCI snoop log** (choose "Full" if prompted).
   - Toggle Bluetooth off and on again to start fresh logging.
3. **Capture Specific Actions**:
   - Open the **realme Link** app and connect your earbuds.
   - Perform the action you want to decode **one at a time**, waiting 3 seconds between actions:
     - Change Noise Mode to ANC, Off, Transparency.
     - Move the Noise Level slider (Mild / Moderate / Max / Smart).
     - Switch EQ Presets: Balanced, Bass Boost, Vocal, Treble.
     - Adjust Custom 5-Band EQ sliders.
     - Toggle Game Mode (Low Latency).
     - Toggle In-Ear Detection.
     - Toggle Dual-Device Connection.
     - Reconfigure touch gestures (tap, double-tap, long-press).
     - Tap "Find my earphones" (Ring Left / Ring Right).
   - Note the timestamp of each action.
4. **Extract the Log File**:
   - Connect your Android phone to your computer via USB (with USB Debugging enabled).
   - Pull the snoop log using `adb`:
     ```sh
     adb bugreport bugreport.zip
     # Or pull directly from common paths:
     adb pull /sdcard/btsnoop_hci.log .
     # On newer Android versions:
     adb pull /data/misc/bluetooth/logs/btsnoop_hci.log .
     ```
5. **Inspect in Wireshark**:
   - Open `btsnoop_hci.log` in **Wireshark**.
   - Apply filter: `btrfcomm` or `btl2cap`.
   - Look for RFCOMM frames starting with `aa` (the OPOv1 sync byte).
   - Identify outbound frames from the phone to the earbuds.

---

### Method 2: macOS Real-Time Sniffer (`Tools/sniff.swift`)

If your earbuds support dual-device connection (multipoint):
1. Connect the earbuds to both your Mac and your phone.
2. Quit the BudsBar app (macOS allows only one active RFCOMM connection per channel per process):
   ```sh
   killall BudsBar 2>/dev/null || true
   ```
3. Run the sniffer tool on RFCOMM channel 15:
   ```sh
   swift Tools/sniff.swift 15
   ```
4. Now open **realme Link** on your phone and tap the control you wish to sniff.
5. In your Mac terminal, you will see real-time hex logs of incoming and outgoing frames:
   ```
   [   4.120] ch15 oppointeraction: aa 0a 00 00 04 04 2c 03 00 01 01 08
   ```

> [!WARNING]
> The buds advertise a `BESOTA` service on channel 13. That is the Bestechnic firmware OTA endpoint; malformed writes there can brick the earbuds. `Tools/sniff.swift` explicitly refuses channel 13. Never send test packets to channel 13.

---

### Understanding the OPOv1 Frame Structure

Frames use the standard OPOv1 format:
```
aa <len> <b2> <b3> <opcode:u16be> <seq> <payloadLen:u16le> <payload...>
```
- `aa`: Sync byte.
- `len`: Total bytes after `len`.
- `opcode`: 2 bytes in big-endian (e.g. `04 04` for set status/noise mode, `06 01` for battery query).
- `seq`: Monotonically increasing sequence number.
- `payloadLen`: 2 bytes in little-endian.
- `payload`: Tagged list `<type> <count> <id> <value> ...`.

---

### Pasting Bytes into `Protocol.swift`

In `Sources/BudsBar/Protocol.swift`, locate the corresponding function:
- `encodeSetTransparencyLevel(_:)`
- `encodeSetEQ(preset:customBands:)`
- `encodeSetLowLatency(_:)`
- `encodeSetEarDetection(_:)`
- `encodeSetDualConnection(_:)`
- `encodeSetGesture(earbud:gesture:action:)`
- `encodeRingBud(side:ring:)`

Replace the opcode, category, and payload bytes in `makeFrame(...)` with the exact sequence identified in your packet capture.

## Verifying changes

`Protocol.swift` carries a `selfCheck()` that replays real captured frames — battery, each
mode, a coalesced pair, a frame split across two reads, and leading garbage — and runs
automatically at launch in debug builds:

```sh
./build.sh debug && "./Realme TWS Mac Controller.app/Contents/MacOS/BudsBar"
# BudsProtocol.selfCheck passed
```

To exercise the radio end to end, `BUDSBAR_TEST=1` commands every ANC level and every mode
in turn and logs what the buds report back. The buds echo the state they actually reached,
so a `LEVEL reported` line matching the command above it is a real confirmation, not just a
successful write:

```sh
BUDSBAR_TEST=1 "./Realme TWS Mac Controller.app/Contents/MacOS/BudsBar"
# TEST commanding ANC Mild, value 4
# LEVEL reported Mild
```

It leaves the buds switched Off when it finishes.

## Credits

The OPOv1 command layout came from
[Cracking OPOv1](https://aasheesh.vercel.app/blog/oneplus-buds) and
[AasheeshLikePanner/cracked-oneplus-buds](https://github.com/AasheeshLikePanner/cracked-oneplus-buds),
which document the protocol for OnePlus Buds over BLE. The frame format carries over intact
to realme hardware on RFCOMM; the notification payload types here were decoded against the
T500 Pro directly.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with realme, OPPO, OnePlus, or BBK Electronics.
