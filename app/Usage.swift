import Foundation

/// Anonymous usage: a random install ID that is never derived from hardware,
/// plus only the fields the user leaves on. Sent when they change or monthly.
enum SharpUsageField: String, CaseIterable, Identifiable {
    case version, macos, model, role, link, display, mode, resolution, country
    var id: String { rawValue }
    var title: String {
        switch self {
        case .version: return "Sharp"
        case .macos: return "macOS"
        case .model: return "Mac"
        case .role: return "Role"
        case .link: return "Cable"
        case .display: return "Display"
        case .mode: return "Mode"
        case .resolution: return "Resolution"
        case .country: return "Country"
        }
    }
}

extension SharpModel {
    private static let usageURL = URL(string: "https://aminerostane.com/api/sharp/ping")!

    var usageID: String {
        if let id = defaults.string(forKey: "usageID") { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "usageID")
        return id
    }

    func usageValue(_ field: SharpUsageField) -> String? {
        switch field {
        case .version: return sharpVersion
        case .macos:
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        case .model:
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: max(size, 1))
            return sysctlbyname("hw.model", &model, &size, nil, 0) == 0 ? String(cString: model) : nil
        case .role: return role == .sender ? "Sender" : "Display"
        case .link: return activeLinkLabel
        case .display:
            let display = role == .receiver ? receiverDisplaySize()
                : peerDisplaySize ?? rememberedPeerID.flatMap { profiles[$0]?.display }
            return display.map { "\($0.width)x\($0.height)" }
        case .mode: return role == .sender ? displayMode.rawValue : nil
        case .resolution: return role == .sender ? resolution.rawValue : nil
        case .country: return "Detected by Cloudflare"
        }
    }

    var usagePayload: [String: Any] {
        var payload: [String: Any] = ["id": usageID]
        for field in SharpUsageField.allCases where !usageHidden.contains(field.rawValue) {
            if field == .country { payload["country"] = true }
            else if let value = usageValue(field) { payload[field.rawValue] = value }
        }
        return payload
    }

    func sendUsageIfNeeded() {
        guard usageEnabled,
              let body = try? JSONSerialization.data(withJSONObject: usagePayload, options: .sortedKeys) else { return }
        let sent = defaults.object(forKey: "usageSentAt") as? Date ?? .distantPast
        guard body != defaults.data(forKey: "usagePayload") || Date().timeIntervalSince(sent) > 30 * 24 * 60 * 60 else { return }
        postUsage(body)
    }

    func setUsageEnabled(_ enabled: Bool) {
        usageEnabled = enabled
        defaults.set(enabled, forKey: "usageEnabled")
        if enabled { sendUsageIfNeeded(); return }
        // One last ping with only the ID clears every stored field.
        if let body = try? JSONSerialization.data(withJSONObject: ["id": usageID]) { postUsage(body) }
    }

    func setUsageField(_ field: SharpUsageField, shared: Bool) {
        if shared { usageHidden.remove(field.rawValue) } else { usageHidden.insert(field.rawValue) }
        defaults.set(Array(usageHidden).sorted(), forKey: "usageHidden")
        sendUsageIfNeeded()
    }

    private func postUsage(_ body: Data) {
        var request = URLRequest(url: Self.usageURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 204 else { return }
            Task { @MainActor [weak self] in
                self?.defaults.set(body, forKey: "usagePayload")
                self?.defaults.set(Date(), forKey: "usageSentAt")
            }
        }.resume()
    }
}
