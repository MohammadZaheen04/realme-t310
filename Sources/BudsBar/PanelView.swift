import SwiftUI

// MARK: - Design Tokens

private extension Color {
    /// WCAG AA secondary text — dark mode near-white, light mode near-black.
    static let sub = Color(nsColor: NSColor(name: nil, dynamicProvider: {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.75, alpha: 1)
            : NSColor(white: 0.30, alpha: 1)
    }))

    /// Hair-line border for cards.
    static let rim = Color(nsColor: NSColor(name: nil, dynamicProvider: {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.09)
            : NSColor(white: 0, alpha: 0.07)
    }))
}

// MARK: - Panel

struct PanelView: View {
    @Bindable var buds: BudsManager

    @State private var showingHelp         = false
    @State private var showingRenameSheet  = false
    @State private var showingAboutSheet   = false
    @State private var showingForgetAlert  = false
    @State private var newDeviceName       = ""

    @AppStorage("anc_card_open")  private var ancOpen  = true
    @AppStorage("info_card_open") private var infoOpen = false

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    headerRow
                    separator

                    if buds.isConnected {
                        batterySection
                        separator
                        noisePicker
                        if buds.mode == .noiseCancellation {
                            separator
                            ancSection
                        }
                        separator
                        infoSection
                    } else {
                        notConnectedBanner
                    }

                    if let err = buds.lastError {
                        errorBanner(err)
                        separator
                    }
                }
            }
            .frame(maxHeight: 560)
        }
        .frame(width: 320)
        .onAppear { buds.refreshConnectionState(); buds.queryBattery() }
        .sheet(isPresented: $showingRenameSheet) { renameSheet }
        .sheet(isPresented: $showingAboutSheet)  { aboutSheet  }
        .alert("Forget Device?", isPresented: $showingForgetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { buds.forgetDevice() }
        } message: {
            Text("This removes \"\(buds.name)\" from BudsBar. Re-pair via Bluetooth Settings to reconnect.")
        }
        .animation(.smooth(duration: 0.22), value: buds.isConnected)
        .animation(.smooth(duration: 0.22), value: buds.mode)
        .animation(.smooth(duration: 0.22), value: buds.ancLevel)
        .animation(.smooth(duration: 0.22), value: ancOpen)
        .animation(.smooth(duration: 0.22), value: infoOpen)
    }

    // MARK: – Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            // Device icon
            Image(systemName: "airpods.pro")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            // Name + status
            VStack(alignment: .leading, spacing: 1) {
                Text(buds.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .help(buds.name)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(statusLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sub)
                }
            }

            Spacer()

            if buds.isBusy {
                ProgressView().controlSize(.small)
            }

            // Connect / Disconnect pill
            if buds.isPaired {
                Button { buds.isConnected ? buds.disconnect() : buds.connect() } label: {
                    Text(buds.isConnected ? "Disconnect" : "Connect")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            buds.isConnected
                                ? Color.primary.opacity(0.08)
                                : Color.accentColor,
                            in: Capsule()
                        )
                        .foregroundStyle(buds.isConnected ? Color.sub : .white)
                }
                .buttonStyle(.plain)
                .disabled(buds.isBusy)
            }

            // ··· menu
            Menu {
                Button { newDeviceName = buds.name; showingRenameSheet = true }
                    label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) { showingForgetAlert = true }
                    label: { Label("Forget Device", systemImage: "trash") }
                Button { showingAboutSheet = true }
                    label: { Label("About / Firmware", systemImage: "info.circle") }
                Divider()
                Button { buds.useMockDevice.toggle() } label: {
                    Label(
                        buds.useMockDevice ? "Use Live Hardware" : "Use Mock Device",
                        systemImage: buds.useMockDevice ? "antenna.radiowaves.left.and.right" : "macbook.and.iphone"
                    )
                }
                Divider()
                Button("Quit BudsBar") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.sub)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusLabel: String {
        guard buds.isPaired else { return "Not paired" }
        return buds.isConnected ? "Connected" : "Disconnected"
    }
    private var statusColor: Color {
        guard buds.isPaired else { return .secondary }
        return buds.isConnected ? .green : .orange
    }

    // MARK: – Not connected

    private var notConnectedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: buds.isPaired ? "earbuds" : "info.circle")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(buds.isPaired
                 ? "Take earbuds out of the case, then tap Connect."
                 : "No paired earbuds found. Pair via Bluetooth Settings or use Mock Device.")
                .font(.system(size: 12))
                .foregroundStyle(Color.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func errorBanner(_ msg: String) -> some View {
        Label(msg, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    // MARK: – Battery

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Battery")

            HStack(spacing: 8) {
                batteryCell("Left",  icon: "earbud.left",
                            pct: buds.battery.left,    charging: buds.battery.isLeftCharging,
                            placement: buds.placement.left)
                batteryCell("Right", icon: "earbud.right",
                            pct: buds.battery.right,   charging: buds.battery.isRightCharging,
                            placement: buds.placement.right)
                batteryCell("Case",  icon: "airpods.pro.chargingcase.wireless.fill",
                            pct: buds.battery.enclosure, charging: buds.battery.isEnclosureCharging)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func batteryCell(
        _ name: String, icon: String,
        pct: Int?, charging: Bool = false,
        placement: BudsPlacement? = nil
    ) -> some View {
        let inCase = placement == .inCase
        let tint   = batteryTint(pct: pct, charging: charging)

        return VStack(spacing: 5) {
            // Icon row
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(inCase && !charging ? Color.sub : tint)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                }
            }

            // Percentage number
            Text(pct.map { "\($0)%" } ?? "–")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(pct == nil ? Color.sub : tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // Label
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.sub)
                .textCase(.uppercase)
                .tracking(0.4)

            // Bar
            ProgressView(value: Double(pct ?? 0), total: 100)
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(maxWidth: .infinity)
                .scaleEffect(x: 1, y: 0.7)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.rim, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            pct.map { "\(name) \($0)%\(charging ? ", charging" : "")\(inCase ? ", in case" : "")" }
                ?? "\(name) unknown"
        )
    }

    private func batteryTint(pct: Int?, charging: Bool) -> Color {
        if charging              { return .green  }
        guard let pct            else { return .secondary }
        if pct < 20              { return .red    }
        if pct < 40              { return Color(hue: 0.11, saturation: 1, brightness: 0.95) }
        return .accentColor
    }

    // MARK: – Noise picker

    private var noisePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Noise Control")
                Spacer()
                if !buds.isControlChannelOpen {
                    Label("Connecting…", systemImage: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.sub)
                }
                Button { showingHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.sub)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingHelp, arrowEdge: .bottom) { helpPopover }
            }

            // Segmented-style row
            HStack(spacing: 0) {
                ForEach(NoiseMode.allCases) { mode in
                    noiseSegment(mode)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.rim, lineWidth: 0.5))
            .disabled(!buds.isControlChannelOpen)
            .opacity(buds.isControlChannelOpen ? 1 : 0.45)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func noiseSegment(_ mode: NoiseMode) -> some View {
        let selected = buds.mode == mode
        return Button { buds.set(mode: mode) } label: {
            VStack(spacing: 5) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.sub)
                Text(mode.label)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.sub)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.12))
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.18), value: selected)
        .accessibilityLabel("\(mode.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Noise Control").font(.system(size: 13, weight: .semibold))
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label("ANC — blocks outside sound", systemImage: "waveform.slash")
                Label("Transparency — lets sound in", systemImage: "ear.and.waveform")
                Label("Off — saves battery",         systemImage: "ear")
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.sub)
        }
        .padding(14)
        .frame(width: 220)
    }

    // MARK: – ANC level

    private var ancSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("ANC Level")

            HStack(spacing: 6) {
                ForEach(ANCLevel.allCases) { lvl in
                    ancSegment(lvl)
                }
            }
            .frame(maxWidth: .infinity)

            if let detail = buds.ancLevel?.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.sub)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func ancSegment(_ level: ANCLevel) -> some View {
        let sel = buds.ancLevel == level
        return Button { buds.set(ancLevel: level) } label: {
            Text(level.label)
                .font(.system(size: 11, weight: sel ? .semibold : .regular))
                .foregroundStyle(sel ? .white : Color.sub)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    sel ? Color.accentColor : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(sel ? Color.clear : Color.rim, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.18), value: sel)
        .accessibilityLabel(level.label)
        .accessibilityAddTraits(sel ? .isSelected : [])
    }

    // MARK: – Device info

    private var infoSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { infoOpen.toggle() }
            } label: {
                HStack {
                    sectionHeader("Device")
                    Spacer()
                    Image(systemName: infoOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.sub)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if infoOpen {
                VStack(spacing: 0) {
                    infoRow("Model",           buds.name)
                    infoRow("Status",          buds.isConnected ? "Connected" : "Disconnected")
                    infoRow("Channel",         buds.isControlChannelOpen ? "Open" : "Standby")
                    infoRow("Mode",            buds.useMockDevice ? "Simulation" : "Live BT")
                    if !buds.useMockDevice {
                        infoRow("Address", buds.deviceInfo.bluetoothAddress)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func infoRow(_ key: String, _ val: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(Color.sub)
            Spacer()
            Text(val)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }

    // MARK: – Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.sub)
            .tracking(0.6)
            .accessibilityAddTraits(.isHeader)
    }

    private var separator: some View {
        Color.rim.frame(height: 0.5)
    }

    // MARK: – Sheets

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Device").font(.headline)
            TextField("Name", text: $newDeviceName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            HStack(spacing: 10) {
                Button("Cancel") { showingRenameSheet = false }.keyboardShortcut(.cancelAction)
                Button("Save") { buds.rename(to: newDeviceName); showingRenameSheet = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 280)
    }

    private var aboutSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "airpods.pro")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Realme TWS Mac Controller").font(.headline)
                    Text("BudsBar v1.0").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                infoRow("Device",   buds.name)
                infoRow("Status",   buds.isConnected ? "Connected" : "Disconnected")
                infoRow("Channel",  buds.isControlChannelOpen ? "Active" : "Closed")
                infoRow("Backend",  buds.useMockDevice ? "Mock" : "Live Bluetooth")
            }
            HStack { Spacer(); Button("Done") { showingAboutSheet = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 300)
    }
}
