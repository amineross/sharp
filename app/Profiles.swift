import Foundation

struct SharpPeerProfile: Codable {
    var name: String
    var display: SharpDisplaySize?
    var resolution: SharpResolution?
    var resolutionChosen: Bool?
    var cursorScale: Double
    var cursorHue: Double
    var audioEnabled: Bool
    var interfaceName: String
}

@MainActor extension SharpModel {
    func saveCurrentProfile() {
        guard let id = rememberedPeerID, var profile = profiles[id] else { return }
        if role == .sender {
            if profile.resolutionChosen == true { profile.resolution = resolution }
            profile.cursorScale = cursorScale
            profile.cursorHue = cursorHue
            profile.audioEnabled = audioEnabled
        }
        profile.interfaceName = preferredInterface
        profiles[id] = profile
        saveProfiles()
    }

    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: "peerProfiles")
        }
    }

    func selectProfile(_ id: String) {
        guard id != rememberedPeerID, let profile = profiles[id] else { return }
        saveCurrentProfile()
        rememberedPeerID = id
        defaults.set(id, forKey: "rememberedPeerID")
        applyProfile(profile)
        peerDisplaySize = nil
        peerName = profile.name
        if configured { restartRole() }
    }

    func applyProfile(_ profile: SharpPeerProfile) {
        preferredInterface = profile.interfaceName
        guard role == .sender else { return }
        resolution = (profile.resolutionChosen == true ? profile.resolution : nil)
            ?? profile.display.map(SharpResolution.testedDefault(for:)) ?? .native
        cursorScale = profile.cursorScale
        cursorHue = profile.cursorHue
        audioEnabled = profile.audioEnabled
    }

    func chooseResolution(_ choice: SharpResolution) {
        guard let id = rememberedPeerID, var profile = profiles[id] else { return }
        resolution = choice
        profile.resolution = choice
        profile.resolutionChosen = true
        profiles[id] = profile
        if configured { settingsChanged() } else { persist() }
    }

    func rememberProfile(_ id: String, name: String, display: SharpDisplaySize? = nil) {
        guard !id.isEmpty else { return }
        if rememberedPeerID != id { saveCurrentProfile() }
        let existing = profiles[id]
        let wasCurrentPeer = rememberedPeerID == id
        var profile = existing ?? SharpPeerProfile(name: name, display: nil, resolution: nil, resolutionChosen: nil,
            cursorScale: wasCurrentPeer ? cursorScale : 1,
            cursorHue: wasCurrentPeer ? cursorHue : 0.94,
            audioEnabled: wasCurrentPeer ? audioEnabled : true,
            interfaceName: wasCurrentPeer ? preferredInterface : "")
        profile.name = name
        if let display { profile.display = display }
        profiles[id] = profile
        if rememberedPeerID != id { applyProfile(profile) }
        rememberedPeerID = id
        defaults.set(id, forKey: "rememberedPeerID")
        defaults.set(sharpPairingCode(peerID, id), forKey: "pairingFingerprint")
        if let display, profile.resolutionChosen != true || !resolution.isSupported(for: display) {
            resolution = SharpResolution.testedDefault(for: display)
            profile.resolution = nil
            profile.resolutionChosen = false
            profiles[id] = profile
        }
        saveProfiles()
    }
}
