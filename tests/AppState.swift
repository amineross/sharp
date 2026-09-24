import AppKit
import Network

@main
struct AppStateCheck {
    @MainActor static func main() {
        let profileSuite = "sh.sharp.test.profiles.\(UUID().uuidString)"
        let profileDefaults = UserDefaults(suiteName: profileSuite)!
        defer { profileDefaults.removePersistentDomain(forName: profileSuite) }
        let profileModel = SharpModel(defaults: profileDefaults)
        let fiveK = SharpDisplaySize(width: 5120, height: 2880)
        assert(SharpResolution.testedDefault(for: fiveK) == .balanced)
        assert(SharpResolution.native.isExperimental(for: fiveK))
        assert(SharpResolution.balanced.size(for: fiveK) == (2560, 1440))
        assert(!SharpResolution.native.isSupported(for: SharpDisplaySize(width: 6016, height: 3384)))
        let wide = SharpDisplaySize(width: 3840, height: 1600)
        assert(SharpResolution.testedDefault(for: wide) == .balanced)
        assert(SharpResolution.balanced.size(for: wide) == (2970, 1238))
        profileModel.rememberProfile("5k", name: "5K iMac", display: fiveK)
        assert(profileModel.resolution == .balanced)
        profileModel.rememberProfile("5k", name: "5K iMac", display: wide)
        assert(profileModel.resolution == .balanced, "Automatic defaults follow changed panel geometry")
        profileModel.rememberProfile("5k", name: "5K iMac", display: fiveK)
        profileModel.chooseResolution(.native)
        profileModel.rememberProfile("wide", name: "Wide Mac", display: wide)
        assert(profileModel.resolution == .balanced)
        profileModel.selectProfile("5k")
        assert(profileModel.resolution == .native, "An opted-in experimental choice survives reconnecting")
        assert(SharpModel(defaults: profileDefaults).resolution == .native)

        let suite = "sh.sharp.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SharpModel(defaults: defaults)
        assert(model.preferredInterface.isEmpty)
        model.chooseInterface("en42")
        assert(SharpModel(defaults: defaults).preferredInterface == "en42")
        model.chooseInterface("")
        assert(model.audioEnabled)
        assert(!model.audioPermissionConfirmed)
        assert(!SharpModel(defaults: defaults).audioPermissionConfirmed)
        model.confirmAudioPermission()
        assert(SharpModel(defaults: defaults).audioPermissionConfirmed, "Successful capture must survive relaunch")
        model.stopAudio()
        assert(model.audioEnabled, "Stopping a route must preserve the audio preference")
        model.setAudioEnabled(false)
        assert(!SharpModel(defaults: defaults).audioEnabled)
        model.setAudioEnabled(true)
        model.peerName = "Display Mac"
        model.linkState = .connected
        model.peerDisplaySize = SharpDisplaySize(width: 2560, height: 1440)
        let control = LineConnection(NWConnection(host: "127.0.0.1", port: 49171, using: .tcp))
        model.control = control
        model.toggleSharing()
        assert(!model.sharingEnabled && model.control === control)
        assert(model.isPeerConnected && model.connectionTitle == "Paused")
        assert(model.connectionDetail == "Display Mac")
        assert(model.peerDisplaySize?.width == 2560)
        assert(model.audioEnabled)
        model.configured = true
        model.cursorScale = 1.3; model.cursorHue = 0.4
        model.cursorChanged()
        assert(model.control === control, "Cursor edits must retain the session")
        assert(defaults.double(forKey: "cursorHue") == 0.4)
        assert(model.handleCursorStyle(ControlMessage(command: "cursor-style", peerID: "test", peerName: "", cursorScale: 1.7, cursorHue: 0.2)))
        assert(model.cursorScale == 1.7 && model.cursorHue == 0.2)
        for endpoint in [0.0, 1.0] {
            assert(model.handleCursorStyle(ControlMessage(command: "cursor-style", peerID: "test", peerName: "", cursorScale: 1.7, cursorHue: endpoint)))
            assert(model.cursorHue == endpoint)
        }
        assert(model.control === control)
        model.control = nil
        control.cancel()
        model.handleReceiverMessage("{\"command\":\"hello\",\"peerID\":\"test-peer\",\"peerName\":\"Sender Mac\",\"sharingEnabled\":false}")
        assert(model.peerName == "Sender Mac" && model.isPeerConnected)
        assert(!model.peerSharingEnabled)
        model.handleReceiverMessage("{\"command\":\"stop\",\"peerID\":\"test-peer\",\"peerName\":\"Sender Mac\"}")
        assert(model.isPeerConnected && !model.isStreaming)
        model.systemWillSleep()
        assert(model.localSleeping && model.connectionTitle == "Paused" && !model.isStreaming)
        model.systemDidWake()
        assert(!model.localSleeping)
        model.configured = false
        model.handleSenderMessage("{\"command\":\"sleeping\",\"peerID\":\"test-peer\",\"peerName\":\"Display Mac\"}")
        assert(model.peerReportedSleep && model.connectionTitle == "Paused" && !model.isStreaming)
        model.handleDisconnect()
        assert(model.connectionTitle == "Paused", "A sleeping peer must stay paused after its connection drops")
        let report = model.diagnosticsText()
        assert(report.contains("Connection: Paused — Display Mac"))
        assert(report.contains("Sender output") && report.contains("Receiver output") && report.contains("Ethernet"))
        print("App state PASS: audio preference, sleep state, peer identity and diagnostics")
    }
}
