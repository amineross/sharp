import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Network
import ServiceManagement
import SwiftUI
import SystemConfiguration
import VideoToolbox

enum SharpColor {
    static let bg = Color(red: 0.145, green: 0.145, blue: 0.135)
    static let panel = Color(red: 0.175, green: 0.174, blue: 0.162)
    static let fg = Color(red: 0.965, green: 0.965, blue: 0.945)
    static let dim = Color(red: 0.61, green: 0.60, blue: 0.56)
    static let line = Color(red: 0.30, green: 0.30, blue: 0.28)
    static let live = Color(red: 0.33, green: 0.84, blue: 0.49)
    static let paused = Color(red: 0.96, green: 0.67, blue: 0.29)
}

struct SharpSymbol: View {
    let name: String
    var fallback = "○"
    var body: some View {
        Group {
            if #available(macOS 11.0, *) {
                Image(systemName: name)
            } else {
                Text(fallback)
            }
        }
    }
}

struct SharpButtonStyle: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(filled ? SharpColor.bg : SharpColor.fg)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(filled ? SharpColor.fg : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(SharpColor.line, lineWidth: filled ? 0 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct SharpToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Button(action: { isOn.toggle() }) {
            HStack {
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? SharpColor.fg : Color.clear)
                    Circle().fill(isOn ? SharpColor.bg : SharpColor.fg).padding(3)
                }
                .frame(width: 43, height: 25)
                .overlay(Capsule().stroke(SharpColor.fg, lineWidth: 1))
            }.contentShape(Rectangle())
        }.buttonStyle(PlainButtonStyle())
    }
}

struct SharpResolutionPicker: View {
    @Binding var selection: SharpResolution
    let target: SharpDisplaySize
    private var showsExperimental: Bool {
        SharpResolution.allCases.contains { $0.isSupported(for: target) && $0.isExperimental(for: target) }
    }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(SharpResolution.allCases) { item in
                Button(action: { selection = item }) {
                    let size = item.size(for: target)
                    VStack(spacing: 2) {
                        Text(item.rawValue)
                            .font(.system(size: 8, weight: .medium)).tracking(0.5)
                        Text("\(size.0)×\(size.1)")
                            .font(.system(size: 12, weight: .medium))
                        if showsExperimental, item.isExperimental(for: target) {
                            Text("Experimental")
                                .font(.system(size: 8)).foregroundColor(selection == item ? SharpColor.bg.opacity(0.7) : SharpColor.dim)
                        }
                    }
                        .foregroundColor(selection == item ? SharpColor.bg : SharpColor.fg)
                        .frame(maxWidth: .infinity).frame(height: showsExperimental ? 56 : 44)
                        .background(selection == item ? SharpColor.fg : Color.clear)
                        .contentShape(Rectangle())
                }.buttonStyle(PlainButtonStyle())
                    .disabled(!item.isSupported(for: target))
                    .opacity(item.isSupported(for: target) ? 1 : 0.35)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(SharpColor.line, lineWidth: 1))
    }
}

struct SharpModeCard: View {
    let mode: SharpMode
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                SharpSymbol(name: mode == .mirror ? "rectangle.on.rectangle" : "rectangle.connected.to.line.below",
                            fallback: mode == .mirror ? "▣" : "▭")
                    .font(.system(size: 24, weight: .light))
                Text(mode.rawValue).font(.system(size: 14, weight: .medium))
            }
            .foregroundColor(selected ? SharpColor.bg : SharpColor.fg)
            .frame(maxWidth: .infinity).frame(height: 78)
            .background(selected ? SharpColor.fg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(SharpColor.line, lineWidth: selected ? 0 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(PlainButtonStyle())
    }
}

struct SharpRoleCard: View {
    let role: SharpRole
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                SharpSymbol(name: role == .sender ? "laptopcomputer" : "display", fallback: "▱")
                    .font(.system(size: 25, weight: .light)).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(role == .sender ? "Send this Mac" : "Use as a display")
                        .font(.system(size: 16, weight: .medium))
                    Text(role == .sender ? "Share this desktop over a cable" : "Show the desktop from another Mac")
                        .font(.system(size: 12)).foregroundColor(selected ? SharpColor.bg.opacity(0.72) : SharpColor.dim)
                }
                Spacer()
                SharpSymbol(name: selected ? "checkmark.circle.fill" : "circle", fallback: selected ? "●" : "○")
            }
            .foregroundColor(selected ? SharpColor.bg : SharpColor.fg)
            .padding(.horizontal, 17).frame(height: 76)
            .background(selected ? SharpColor.fg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(SharpColor.line, lineWidth: selected ? 0 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(PlainButtonStyle())
    }
}

struct CursorPreview: View {
    let scale: Double
    let hue: Double
    private var cursorImage: NSImage? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("Cursors/Normal Select.cur")
        return url.flatMap(NSImage.init(contentsOf:)).map { SharpCursorImage($0, hue) }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11).fill(SharpColor.panel)
            if let cursorImage {
                Image(nsImage: cursorImage).renderingMode(.original).resizable().interpolation(.high)
                    .id(hue)
                    .frame(width: 28 * scale, height: 28 * scale)
                    .offset(x: 8 * scale, y: 4 * scale)
            } else {
                SharpSymbol(name: "cursorarrow", fallback: "↖").font(.system(size: 24 * scale, weight: .regular))
            }
        }.frame(width: 76, height: 62)
    }
}

struct PermissionView: View {
    @EnvironmentObject var model: SharpModel
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sharp").font(.system(size: 27, weight: .semibold))
            HStack(spacing: 10) {
                SharpRoleCard(role: .sender, selected: model.role == .sender) { model.role = .sender; model.runProbes() }
                SharpRoleCard(role: .receiver, selected: model.role == .receiver) { model.role = .receiver; model.runProbes() }
            }
            if model.role == .sender {
                permission("Screen Recording", symbol: "rectangle.on.rectangle", granted: !model.needsScreenPermission) {
                    model.requestScreenPermission()
                }
                if #available(macOS 14.2, *) {
                    permission("System Audio", symbol: "speaker.wave.2", granted: model.audioPermissionConfirmed) {
                        model.requestAudioPermission()
                    }
                }
            }
            if #available(macOS 15.0, *) {
                permission(model.localNetworkDenied ? "Local Network · Allow in System Settings" : "Local Network",
                           symbol: "network", granted: model.localNetworkRequested && !model.localNetworkDenied) {
                    if model.localNetworkDenied { model.openLocalNetworkSettings() } else { model.requestLocalNetworkAccess() }
                }
            }
            Button("Done") { model.saveAndStart(); dismiss() }
                .buttonStyle(SharpButtonStyle(filled: true)).disabled(model.needsScreenPermission)
                .opacity(model.needsScreenPermission ? 0.45 : 1)
        }
        .padding(24).frame(width: 580)
        .background(SharpColor.bg).foregroundColor(SharpColor.fg)
        .onAppear { model.runProbes(); model.requestLocalNetworkAccess() }
    }
    private func permission(_ title: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SharpSymbol(name: symbol, fallback: "○").font(.system(size: 22)).frame(width: 30)
                Text(title).font(.system(size: 16, weight: .medium))
                Spacer()
                SharpSymbol(name: granted ? "checkmark.circle.fill" : "arrow.up.right", fallback: granted ? "✓" : "↗")
            }.padding(18).background(granted ? SharpColor.fg : SharpColor.panel)
                .foregroundColor(granted ? SharpColor.bg : SharpColor.fg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(PlainButtonStyle())
    }
}

final class HueSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: rect.height/2, yRadius: rect.height/2).addClip()
        let colors = [NSColor.white] + (0...12).map { NSColor(calibratedHue: CGFloat($0)/12, saturation: 0.65, brightness: 1, alpha: 1) } + [NSColor.black]
        NSGradient(colors: colors)?.draw(in: rect, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}

struct HueSlider: NSViewRepresentable {
    @Binding var value: Double
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = HueSliderCell()
        slider.minValue = 0; slider.maxValue = 1
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.update(_:))
        slider.setAccessibilityLabel("Cursor color")
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.owner = self
        slider.doubleValue = value
    }
    final class Coordinator: NSObject {
        var owner: HueSlider
        init(_ owner: HueSlider) { self.owner = owner }
        @objc func update(_ slider: NSSlider) { owner.value = slider.doubleValue }
    }
}

struct InstallView: View {
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                SharpSymbol(name: "arrow.down.app", fallback: "↓")
                    .font(.system(size: 30, weight: .light)).frame(width: 38)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Install Sharp").font(.system(size: 25, weight: .semibold))
                    Text("Sharp must live in Applications to stay ready after restarts.")
                        .font(.system(size: 13)).foregroundColor(SharpColor.dim)
                }
            }
            Button("Move to Applications") { install() }
                .buttonStyle(SharpButtonStyle(filled: true))
            Text("Sharp will reopen from Applications and keep your current settings.")
                .font(.system(size: 11)).foregroundColor(SharpColor.dim)
        }
        .padding(28).frame(width: 500, height: 230, alignment: .topLeading)
        .background(SharpColor.bg).foregroundColor(SharpColor.fg)
    }
}

struct SharpAudioButton: View {
    @EnvironmentObject var model: SharpModel
    var body: some View {
        Button(action: { model.toggleAudio() }) {
            SharpSymbol(name: model.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash", fallback: model.audioEnabled ? "🔊" : "🔇")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(model.audioActive ? SharpColor.live : SharpColor.dim)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!model.canRouteAudio)
        .accessibility(hint: Text(model.audioEnabled ? "Return audio to the sender" : "Play audio on the display Mac"))
        .accessibility(label: Text(model.audioActive ? "Audio on display Mac" : model.audioEnabled ? "Audio enabled for display Mac" : "Audio on sender"))
        .accessibility(value: Text(model.audioEnabled ? "On" : "Off"))
    }
}

struct SharpMenuView: View {
    @EnvironmentObject var model: SharpModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Circle().fill(model.connectionStatus == .connected ? SharpColor.live :
                                      model.connectionStatus == .paused ? SharpColor.paused : SharpColor.dim)
                            .frame(width: 8, height: 8)
                        Text(model.connectionTitle)
                            .font(.system(size: 18, weight: .semibold)).lineLimit(1)
                    }
                    Text(model.connectionDetail).font(.system(size: 12)).foregroundColor(SharpColor.dim)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                SharpAudioButton().environmentObject(model)
                Button(action: { AppDelegate.shared?.showSettings() }) {
                    SharpSymbol(name: "gearshape", fallback: "⚙").font(.system(size: 18, weight: .regular))
                        .foregroundColor(SharpColor.fg).frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }.buttonStyle(PlainButtonStyle())
            }

            if model.role == .sender {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Display").font(.system(size: 10, weight: .medium)).foregroundColor(SharpColor.dim)
                    HStack(spacing: 10) {
                        SharpModeCard(mode: .mirror, selected: model.displayMode == .mirror) { model.chooseDisplayMode(.mirror) }
                        SharpModeCard(mode: .extend, selected: model.displayMode == .extend) { model.chooseDisplayMode(.extend) }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Cursor").font(.system(size: 10, weight: .medium)).foregroundColor(SharpColor.dim)
                    HStack(spacing: 14) {
                        CursorPreview(scale: model.cursorScale, hue: model.cursorHue)
                        VStack(spacing: 12) {
                            Slider(value: Binding(get: { model.cursorScale }, set: { model.cursorScale = $0; model.cursorChanged() }), in: 0.6...2.0).accentColor(SharpColor.fg).accessibility(label: Text("Cursor size"))
                            HueSlider(value: Binding(get: { model.cursorHue }, set: { model.cursorHue = $0; model.cursorChanged() }))
                        }
                    }

                }
            }

            Button(model.sharingEnabled ? "Pause Sharp" : "Resume Sharp") { model.toggleSharing() }
                .buttonStyle(SharpButtonStyle(filled: model.sharingEnabled))
            HStack {
                Spacer()
                Button("Quit Sharp") { model.shutdown(); NSApp.terminate(nil) }
                    .buttonStyle(PlainButtonStyle()).font(.system(size: 12)).foregroundColor(SharpColor.dim)
            }.padding(.top, -6)
        }
        .padding(20).frame(width: 340)
        .background(SharpColor.bg).foregroundColor(SharpColor.fg)
    }


}

struct SharpSettingsView: View {
    @EnvironmentObject var model: SharpModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sharp").font(.system(size: 27, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(model.connectionStatus == .connected ? SharpColor.live :
                                      model.connectionStatus == .paused ? SharpColor.paused : SharpColor.dim)
                            .frame(width: 6, height: 6)
                        Text("\(model.connectionTitle) · \(model.connectionDetail)")
                            .foregroundColor(SharpColor.dim).font(.system(size: 12)).lineLimit(1)
                    }
                }
                Spacer()
                SharpAudioButton().environmentObject(model)
                Button(action: { AppDelegate.shared?.closeSettings() }) {
                    SharpSymbol(name: "xmark.circle", fallback: "×").font(.system(size: 19)).foregroundColor(SharpColor.dim)
                }.buttonStyle(PlainButtonStyle())
            }

            HStack(spacing: 10) {
                SharpRoleCard(role: .sender, selected: model.role == .sender) { model.chooseRole(.sender) }
                SharpRoleCard(role: .receiver, selected: model.role == .receiver) { model.chooseRole(.receiver) }
            }
            if model.role == .sender {
                Text("Resolution").font(.system(size: 10, weight: .medium)).foregroundColor(SharpColor.dim)
                if let target = model.peerDisplaySize {
                    SharpResolutionPicker(selection: Binding(
                        get: { model.resolution },
                        set: { model.chooseResolution($0) }
                    ), target: target)
                    Text("Matched to the display Mac’s \(target.width)×\(target.height) panel.")
                        .font(.system(size: 11)).foregroundColor(SharpColor.dim)
                } else {
                    Text("Connect a Sharp display to see resolutions matched to its panel.")
                        .font(.system(size: 12)).foregroundColor(SharpColor.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(SharpColor.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            VStack(spacing: 15) {
                SharpToggle(title: "Start Sharp when I log in", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.launchAtLogin = $0; model.savePreferences() }
                ))
                Rectangle().fill(SharpColor.line).frame(height: 1)
                SharpToggle(title: "Save continuous logs", isOn: Binding(
                    get: { model.logsEnabled },
                    set: { model.logsEnabled = $0; model.savePreferences() }
                ))
            }.padding(16).background(SharpColor.panel).clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                Button("Reports") { AppDelegate.shared?.showDiagnostics() }
                    .buttonStyle(SharpButtonStyle(filled: false))
                if model.hasRememberedPeer {
                    Button("Forget paired Mac") { model.forgetPairing() }
                        .buttonStyle(SharpButtonStyle(filled: false))
                }
                Button("Advanced") { AppDelegate.shared?.showAdvanced() }
                    .buttonStyle(SharpButtonStyle(filled: false))
            }
            HStack {
                HStack(spacing: 0) {
                    Text("Sharp \(sharpVersion) by ")
                    Button(action: { NSWorkspace.shared.open(URL(string: "https://aminerostane.com")!) }) {
                        Text("Amine Rostane").underline()
                    }.buttonStyle(PlainButtonStyle())
                }.font(.system(size: 11)).foregroundColor(SharpColor.dim)
                Spacer()
                Button("Quit Sharp") { model.shutdown(); NSApp.terminate(nil) }
                    .buttonStyle(PlainButtonStyle()).foregroundColor(SharpColor.dim)
            }
        }
        .padding(28).frame(width: 620)
        .background(SharpColor.bg).foregroundColor(SharpColor.fg)
    }
}

struct SharpAdvancedView: View {
    @EnvironmentObject var model: SharpModel
    private var selectedProfile: SharpPeerProfile? {
        model.rememberedPeerID.flatMap { model.profiles[$0] }
    }
    private var interfaceNames: [String] {
        let connected = activeDirectInterfaces().map(\.interface.name)
        return Array(Set(connected + [model.preferredInterface])).filter { !$0.isEmpty }.sorted()
    }
    private func interfaceLabel(_ name: String) -> String {
        let title = directInterface(named: name)?.displayName ?? name
        return ipv4Address(interfaceName: name).map { "\(title) · \($0)" } ?? "\(title) · not connected"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                Text("Advanced").font(.system(size: 27, weight: .semibold))
                Spacer()
                Button(action: { AppDelegate.shared?.closeAdvanced() }) {
                    SharpSymbol(name: "xmark.circle", fallback: "×").font(.system(size: 19)).foregroundColor(SharpColor.dim)
                }.buttonStyle(PlainButtonStyle())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Paired Mac").font(.system(size: 12, weight: .medium))
                if !model.profiles.isEmpty {
                    Picker("Paired Mac", selection: Binding(
                        get: { model.rememberedPeerID ?? "" },
                        set: { model.selectProfile($0) }
                    )) {
                        ForEach(model.profiles.keys.sorted(), id: \.self) { id in
                            Text(model.profiles[id]?.name ?? id).tag(id)
                        }
                    }.labelsHidden()
                } else {
                    Text("Connect a Mac to create its profile.")
                        .font(.system(size: 12)).foregroundColor(SharpColor.dim)
                }
            }

            if selectedProfile != nil {

            VStack(alignment: .leading, spacing: 7) {
                Text("Connection").font(.system(size: 12, weight: .medium))
                Picker("Connection", selection: Binding(
                    get: { model.preferredInterface }, set: { model.chooseInterface($0) }
                )) {
                    Text("Automatic").tag("")
                    ForEach(interfaceNames, id: \.self) { name in
                        Text(interfaceLabel(name)).tag(name)
                    }
                }.labelsHidden()
                Text("Automatic prefers Thunderbolt, then a direct Ethernet cable.").font(.system(size: 11)).foregroundColor(SharpColor.dim)
            }

            if model.role == .sender {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Default resolution").font(.system(size: 12, weight: .medium))
                    if let target = model.peerDisplaySize ?? selectedProfile?.display {
                        SharpResolutionPicker(selection: Binding(
                            get: { model.resolution },
                            set: { model.chooseResolution($0) }
                        ), target: target)
                        Text("Based on this Mac’s last reported \(target.width)×\(target.height) display.")
                            .font(.system(size: 11)).foregroundColor(SharpColor.dim)
                    } else {
                        Text("Connect this Mac to see its resolution choices.")
                            .font(.system(size: 12)).foregroundColor(SharpColor.dim)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Default cursor").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 14) {
                        CursorPreview(scale: model.cursorScale, hue: model.cursorHue)
                        VStack(spacing: 12) {
                            Slider(value: Binding(get: { model.cursorScale }, set: { model.cursorScale = $0; model.cursorChanged() }), in: 0.6...2.0)
                                .accentColor(SharpColor.fg).accessibility(label: Text("Default cursor size"))
                            HueSlider(value: Binding(get: { model.cursorHue }, set: { model.cursorHue = $0; model.cursorChanged() }))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Default audio output").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 10) {
                        Button("This Mac") { if model.audioEnabled { model.setAudioEnabled(false) } }
                            .buttonStyle(SharpButtonStyle(filled: !model.audioEnabled))
                        Button("Display Mac") { if !model.audioEnabled { model.setAudioEnabled(true) } }
                            .buttonStyle(SharpButtonStyle(filled: model.audioEnabled))
                    }
                }
            } else {
                Text("Display defaults are set on the sending Mac.")
                    .font(.system(size: 12)).foregroundColor(SharpColor.dim)
            }
            }
        }
        .padding(28).frame(width: 520)
        .background(SharpColor.bg).foregroundColor(SharpColor.fg)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: SharpModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Compatibility").font(.system(size: 27, weight: .semibold))
                Spacer()
                Button(action: { AppDelegate.shared?.closeDiagnostics() }) {
                    SharpSymbol(name: "xmark.circle", fallback: "×").font(.system(size: 19)).foregroundColor(SharpColor.dim)
                }.buttonStyle(PlainButtonStyle())
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.probes) { probe in
                        HStack(alignment: .top, spacing: 13) {
                            SharpSymbol(name: probe.level == .pass ? "checkmark.circle" : probe.level == .warning ? "exclamationmark.triangle" : "xmark.circle",
                                        fallback: probe.level == .pass ? "✓" : probe.level == .warning ? "!" : "×")
                                .font(.system(size: 17)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(probe.title).font(.system(size: 14, weight: .medium))
                                Text(probe.detail).font(.system(size: 12)).foregroundColor(SharpColor.dim)
                            }
                            Spacer()
                        }.padding(.vertical, 12)
                        Rectangle().fill(SharpColor.line).frame(height: 1)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Create report") { model.createDiagnosticsReport() }.buttonStyle(SharpButtonStyle(filled: true))
                Button("Run benchmarks") { model.runBenchmark() }
                    .buttonStyle(SharpButtonStyle(filled: false))
                    .disabled(model.role != .sender || !model.isStreaming || model.benchmarkRunning)
                Button("Open reports") { model.revealReports() }.buttonStyle(SharpButtonStyle(filled: false))
            }
            Text(model.benchmarkStatus.isEmpty ? "Run the visual test suite on the display Mac." : model.benchmarkStatus)
                .font(.system(size: 11)).foregroundColor(SharpColor.dim)
        }.padding(28).frame(width: 560, height: 500)
        .background(SharpColor.bg).foregroundColor(SharpColor.fg)
    }
}
