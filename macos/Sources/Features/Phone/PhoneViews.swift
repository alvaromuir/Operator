#if os(macOS)
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The phone setup window: Tailscale step by step, then the devices that can reach this Mac.
enum PhoneSetup {
    static let windowID = "phone"

    static func show() {
        guard OperatorSettings.isOn(.phone) else { return }
        TailscaleMonitor.shared.watch()
        AgentToolWindows.show(id: windowID, title: "Phone", size: NSSize(width: 560, height: 600)) {
            PhoneSetupView()
        }
    }
}

// MARK: - Corner badge

/// Bottom right of the terminal: a small phone that says whether phone access is live.
/// Dim when it's off, gold while it waits for a phone, green with a phone connected.
/// Hovering names the state; clicking opens the Phone window.
struct PhoneCornerBadge: View {
    @ObservedObject private var monitor = TailscaleMonitor.shared
    @ObservedObject private var server = PhoneServer.shared
    @ObservedObject private var phones = PhoneDevices.shared
    @State private var hovering = false

    private var connectedNames: [String] {
        phones.devices.filter { server.connected[$0.id] != nil }.map(\.name)
    }

    private var label: String {
        guard server.running else {
            return monitor.status.isReady ? "Phone access off" : "Phone · \(monitor.status.summary)"
        }
        if server.servePort == nil && !PhoneServer.devMode { return "Phone · starting" }
        let names = connectedNames
        switch names.count {
        case 0: return "Phone · on, no phone connected"
        case 1: return "Phone · live · \(names[0])"
        default: return "Phone · live · \(names.count) phones"
        }
    }

    private var color: Color {
        guard server.running else { return Operator.dim }
        if server.error != nil { return Operator.danger }
        return server.connected.isEmpty ? Operator.gold : Operator.live
    }

    var body: some View {
        Button(action: PhoneSetup.show) {
            HStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    PixelIconView(icon: .phone, color: server.running ? color : Operator.muted, pixel: 1.2)
                    Circle().fill(color).frame(width: 5, height: 5).offset(x: 3, y: -2)
                }
                if hovering {
                    Text(label)
                        .font(Operator.font(11, weight: .medium))
                        .foregroundColor(Operator.text)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, hovering ? 9 : 6)
            .frame(height: 22)
            .background(Capsule().fill(Operator.panel.opacity(hovering ? 0.96 : 0.75)))
            .overlay(Capsule().stroke(hovering ? Operator.lineStrong : Operator.line, lineWidth: 1))
            .opacity(hovering || server.running ? 1 : 0.7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help("Use this terminal from your phone. Click to set up, pair a phone or see who's connected.")
        .accessibilityLabel(label)
    }
}

// MARK: - Setup window

private struct PhoneSetupView: View {
    @ObservedObject private var monitor = TailscaleMonitor.shared
    @ObservedObject private var server = PhoneServer.shared
    @ObservedObject private var phones = PhoneDevices.shared

    private enum StepState { case done, current, later }

    @State private var showSetup = false

    /// Tailscale is ready for phone access: the window leads with pairing and phones.
    private func ready(_ s: TailscaleStatus) -> Bool { s.state == .running && s.magicDNS && s.httpsEnabled }

    var body: some View {
        let status = monitor.status
        VStack(alignment: .leading, spacing: 0) {
            OperatorWindowTitle(icon: .phone, title: "Phone",
                               subtitle: "Use this Mac's terminal from your phone, over your own private Tailscale network")
                .padding(.horizontal, 22)
                .padding(.top, 34)
                .padding(.bottom, 16)
            Rectangle().fill(Operator.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if ready(status) {
                        access
                        devices(status)
                        setupSummary(status)
                    } else {
                        checklist(status)
                        if status.state == .running { devices(status) }
                    }
                    if let error = monitor.error {
                        Text(error)
                            .font(Operator.font(11))
                            .foregroundColor(Operator.danger)
                            .textSelection(.enabled)
                    }
                    Text("Operator only uses Tailscale inside your own tailnet. It never turns on Funnel, which would put your terminal on the public internet.")
                        .font(Operator.font(10.5))
                        .foregroundColor(Operator.dim)
                        .padding(.top, 4)
                }
                .padding(22)
            }
        }
        .frame(minWidth: 480, minHeight: 480)
        .onAppear(perform: pairIfFirstPhone)
        .onChange(of: server.servePort) { _ in pairIfFirstPhone() }
    }

    /// No phone paired yet: have the code ready, since that's what the window is for.
    private func pairIfFirstPhone() {
        guard server.running, server.url != nil, phones.devices.isEmpty, phones.pairingCode == nil else { return }
        phones.newPairingCode()
    }

    private func checklist(_ status: TailscaleStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Install Tailscale", state: installState(status),
                 detail: "Free for personal use. It connects your Mac and phone privately, on Wi-Fi or cellular.") {
                Button(ToolPath.find("brew") == nil ? "Download…" : "Install with Homebrew") { monitor.install() }
                    .buttonStyle(OperatorButtonStyle(prominent: true))
            }
            step(2, "Turn it on and sign in", state: connectState(status), detail: connectDetail(status)) {
                if status.state == .appNotRunning {
                    Button("Open Tailscale") { monitor.openApp() }.buttonStyle(OperatorButtonStyle(prominent: true))
                } else {
                    Button(status.state == .needsLogin ? "Sign in…" : "Turn on") { monitor.connect() }
                        .buttonStyle(OperatorButtonStyle(prominent: true))
                        .disabled(monitor.busy)
                }
            }
            step(3, "Turn on HTTPS for your tailnet", state: httpsState(status),
                 detail: "One switch on Tailscale's DNS page: MagicDNS and HTTPS Certificates. The phone app needs it to install to your home screen and notify you. This page notices when it's on.") {
                Button("Open DNS settings…") { monitor.openHTTPSSettings() }.buttonStyle(OperatorButtonStyle(prominent: true))
            }
            step(4, "Add your phone", state: phoneState(status),
                 detail: "Install Tailscale on your phone and sign in with the same account.") {
                HStack(alignment: .center, spacing: 14) {
                    QRCodeView(text: "https://tailscale.com/download", size: 104)
                    Text("Scan with your phone's camera")
                        .font(Operator.font(11))
                        .foregroundColor(Operator.muted)
                }
            }
        }
    }

    /// The finished checklist, folded away.
    private func setupSummary(_ status: TailscaleStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showSetup.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Operator.live)
                    Text("Tailscale is set up").font(Operator.font(12, weight: .semibold)).foregroundColor(Operator.text)
                    if let login = status.loginName {
                        Text(login).font(Operator.font(11)).foregroundColor(Operator.muted).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: showSetup ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(Operator.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showSetup { checklist(status) }
        }
        .padding(.top, 8)
    }

    // MARK: Steps

    private func installState(_ s: TailscaleStatus) -> StepState { s.state == .notInstalled ? .current : .done }

    private func connectState(_ s: TailscaleStatus) -> StepState {
        switch s.state {
        case .notInstalled: return .later
        case .running: return .done
        default: return .current
        }
    }

    private func connectDetail(_ s: TailscaleStatus) -> String {
        switch s.state {
        case .appNotRunning: return "Tailscale is installed but not running."
        case .stopped: return "Tailscale is switched off."
        case .needsLogin: return "Sign in in your browser; this page continues by itself."
        case .starting: return "Connecting…"
        default: return s.dnsName.map { "Connected as \($0)" } ?? "Connected"
        }
    }

    private func httpsState(_ s: TailscaleStatus) -> StepState {
        guard s.state == .running else { return .later }
        return s.magicDNS && s.httpsEnabled ? .done : .current
    }

    private func phoneState(_ s: TailscaleStatus) -> StepState {
        guard s.state == .running else { return .later }
        return s.phones.isEmpty ? .current : .done
    }

    private func step<Action: View>(_ number: Int, _ title: String, state: StepState, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(state == .done ? Operator.live.opacity(0.18) : state == .current ? Operator.gold.opacity(0.18) : Operator.raised)
                Circle()
                    .strokeBorder(state == .done ? Operator.live : state == .current ? Operator.gold : Operator.line, lineWidth: 1)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Operator.live)
                } else {
                    Text("\(number)").font(Operator.font(11, weight: .semibold))
                        .foregroundColor(state == .current ? Operator.gold : Operator.dim)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Operator.font(13, weight: .semibold))
                    .foregroundColor(state == .later ? Operator.dim : Operator.text)
                if state != .done || number == 2 {
                    Text(detail)
                        .font(Operator.font(11))
                        .foregroundColor(state == .later ? Operator.dim : Operator.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state == .current { action().padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(state == .current ? Operator.panel : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(state == .current ? Operator.gold.opacity(0.35) : Operator.line.opacity(0.6)))
    }

    // MARK: Devices

    private func devices(_ s: TailscaleStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OperatorSectionLabel("On your tailnet")
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundColor(Operator.gold)
                Text("This Mac").font(Operator.font(12, weight: .semibold)).foregroundColor(Operator.text)
                Text(s.dnsName ?? s.ip ?? "").font(Operator.font(11)).foregroundColor(Operator.muted)
                    .textSelection(.enabled).lineLimit(1)
            }
            ForEach(s.phones) { phone in
                HStack(spacing: 8) {
                    Image(systemName: "iphone").foregroundColor(phone.online ? Operator.live : Operator.dim)
                    Text(phone.name).font(Operator.font(12, weight: .semibold)).foregroundColor(Operator.text)
                    Text(phone.online ? "online" : "offline").font(Operator.font(11))
                        .foregroundColor(phone.online ? Operator.live : Operator.dim)
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: Phone access

    private var access: some View {
        VStack(alignment: .leading, spacing: 10) {
            OperatorSectionLabel("Phone access")
            if !server.running {
                Text("Turn it on to use this Mac's terminal from your paired phones. Only devices signed in to your own Tailscale account can reach it, and each phone has to be paired here first.")
                    .font(Operator.font(11))
                    .foregroundColor(Operator.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn on phone access") { server.turnOn() }
                    .buttonStyle(OperatorButtonStyle(prominent: true))
                    .disabled(monitor.busy)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    Circle().fill(server.connected.isEmpty ? Operator.gold : Operator.live).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(liveSummary).font(Operator.font(13, weight: .semibold)).foregroundColor(Operator.text)
                        if let url = server.url {
                            Text(url.absoluteString).font(Operator.font(11)).foregroundColor(Operator.muted)
                                .textSelection(.enabled)
                        } else {
                            Text(monitor.busy ? "Setting up Tailscale Serve…" : "Waiting for Tailscale Serve")
                                .font(Operator.font(11)).foregroundColor(Operator.muted)
                        }
                    }
                    Spacer()
                    Button("Turn off") { server.turnOff() }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Operator.panel))
                pairing
                pairedList
            }
            if let error = server.error {
                Text(error).font(Operator.font(11)).foregroundColor(Operator.danger).textSelection(.enabled)
            }
        }
        .padding(.top, 8)
    }

    private var liveSummary: String {
        switch server.connected.count {
        case 0: return "On · waiting for a phone"
        case 1: return "Live · " + (phones.devices.first { server.connected[$0.id] != nil }?.name ?? "1 phone") + " connected"
        default: return "Live · \(server.connected.count) phones connected"
        }
    }

    @ViewBuilder
    private var pairing: some View {
        if let code = phones.pairingCode, let url = server.url {
            HStack(alignment: .center, spacing: 16) {
                QRCodeView(text: url.absoluteString + "#pair=" + code, size: 150)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan with your phone's camera").font(Operator.font(12.5, weight: .semibold)).foregroundColor(Operator.text)
                    Text(code)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundColor(Operator.gold)
                        .textSelection(.enabled)
                    Text("Or open \(url.host ?? "the address") on your phone and type this code. It works once, for 10 minutes. Your phone has to be on Tailscale.")
                        .font(Operator.font(11)).foregroundColor(Operator.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") { phones.cancelPairing() }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Operator.panel))
        } else if server.url != nil {
            Button(phones.devices.isEmpty ? "Pair a phone…" : "Pair another phone…") { phones.newPairingCode() }
                .buttonStyle(OperatorButtonStyle(prominent: phones.devices.isEmpty))
        }
    }

    @ViewBuilder
    private var pairedList: some View {
        if !phones.devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(phones.devices) { device in
                    let online = server.connected[device.id] != nil
                    HStack(spacing: 8) {
                        Image(systemName: "iphone").foregroundColor(online ? Operator.live : Operator.muted)
                        Text(device.name).font(Operator.font(12, weight: .semibold)).foregroundColor(Operator.text)
                        Text(online ? "connected" : device.lastSeen.map { "last used " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "")
                            .font(Operator.font(11)).foregroundColor(online ? Operator.live : Operator.dim)
                        Spacer()
                        Button("Remove") { phones.remove(device.id) }
                    }
                }
                if phones.devices.count > 1 {
                    Button("Remove all phones") { phones.removeAll() }
                }
            }
        }
    }
}

/// A QR code for `text`, drawn crisp at any size.
struct QRCodeView: View {
    let text: String
    let size: CGFloat

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: size, height: size)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
        }
    }

    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
#endif
