import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Network
import ServiceManagement
import SwiftUI
import SystemConfiguration
import VideoToolbox

enum SharpRole: String, CaseIterable, Identifiable, Codable {
    case sender = "Send this Mac"
    case receiver = "Use this Mac as display"
    var id: String { rawValue }
}

enum SharpMode: String, CaseIterable, Identifiable, Codable {
    case mirror = "Mirror"
    case extend = "Extend"
    var id: String { rawValue }
}

enum SharpResolution: String, CaseIterable, Identifiable, Codable {
    case native = "Native"
    case high = "High"
    case balanced = "Balanced"
    case performance = "Performance"
    var id: String { rawValue }
    static let testedPixelBudget = 2560 * 1440

    static func testedDefault(for target: SharpDisplaySize) -> SharpResolution {
        allCases.first(where: {
            let size = $0.size(for: target)
            return size.0 * size.1 <= testedPixelBudget && $0.isSupported(for: target)
        }) ?? .performance
    }

    func isExperimental(for target: SharpDisplaySize) -> Bool {
        let size = size(for: target)
        return size.0 * size.1 > Self.testedPixelBudget
    }

    func isSupported(for target: SharpDisplaySize) -> Bool {
        let size = size(for: target)
        return size.0 <= 8192 && size.1 <= 8192 &&
            ((size.0 + 63) / 64) * ((size.1 + 63) / 64) <= 4096
    }

    func size(for target: SharpDisplaySize) -> (Int, Int) {
        let sizes = SharpResolution.presets(for: target)
        return sizes[SharpResolution.allCases.firstIndex(of: self) ?? 0]
    }

    static func presets(for target: SharpDisplaySize) -> [(Int, Int)] {
        let nativeWidth = max(640, target.width)
        let nativeHeight = max(360, target.height)
        let aspect = Double(nativeWidth) / Double(nativeHeight)
        var standardHeights = [2160, 1440, 1080, 720, 540, 480, 360]
        if nativeWidth * nativeHeight > testedPixelBudget,
           let index = standardHeights.firstIndex(where: {
               $0 < nativeHeight && Int((Double($0) * aspect).rounded()) * $0 <= testedPixelBudget
           }) {
            var budgetHeight = Int(sqrt(Double(testedPixelBudget) / aspect))
            budgetHeight -= budgetHeight % 2
            while Int((Double(budgetHeight) * aspect).rounded()) * budgetHeight > testedPixelBudget {
                budgetHeight -= 2
            }
            if budgetHeight > standardHeights[index] { standardHeights[index] = budgetHeight }
        }
        var sizes: [(Int, Int)] = [(nativeWidth, nativeHeight)]
        for height in standardHeights where height < nativeHeight && sizes.count < 4 {
            var width = Int((Double(height) * aspect).rounded())
            width -= width % 2
            sizes.append((max(640, width), height))
        }
        let fallbackScales = [0.75, 0.5, 0.375, 0.25]
        for scale in fallbackScales where sizes.count < 4 {
            var width = Int((Double(nativeWidth) * scale).rounded())
            var height = Int((Double(nativeHeight) * scale).rounded())
            width -= width % 2
            height -= height % 2
            let candidate = (max(160, width), max(90, height))
            if !sizes.contains(where: { $0.0 == candidate.0 && $0.1 == candidate.1 }) {
                sizes.append(candidate)
            }
        }
        while sizes.count < 4 {
            let previous = sizes.last ?? (nativeWidth, nativeHeight)
            var width = max(160, Int((Double(previous.0) * 0.75).rounded()))
            var height = max(90, Int((Double(previous.1) * 0.75).rounded()))
            width -= width % 2
            height -= height % 2
            if width == previous.0 && height == previous.1 {
                width = max(2, previous.0 - 2)
                height = max(2, previous.1 - 2)
            }
            sizes.append((width, height))
        }
        return Array(sizes.prefix(4))
    }
}

struct SharpDisplaySize: Equatable, Codable {
    let width: Int
    let height: Int
}

enum SharpLinkState {
    case waiting
    case connecting
    case connected
    case sleeping
}

enum SharpConnectionStatus: String {
    case connected = "Connected"
    case paused = "Paused"
    case disconnected = "Disconnected"
}

enum ProbeLevel: String, Codable { case pass, warning, fatal }

struct ProbeResult: Identifiable, Codable {
    let id: String
    let level: ProbeLevel
    let title: String
    let detail: String
}

struct ControlMessage: Codable {
    var command: String
    var peerID: String
    var peerName: String
    var width: Int?
    var height: Int?
    var mode: String?
    var cursorScale: Double?
    var cursorHue: Double?
    var sharingEnabled: Bool?
    var receiverIP: String?
    var reason: String?
    var audioEnabled: Bool?
    var audioToken: String?
    var audioSupported: Bool?
    var benchmarkLine: String?
}

final class LineConnection {
    let connection: NWConnection
    private var buffer = Data()
    var onLine: ((String) -> Void)?
    var onClosed: (() -> Void)?
    private var closed = false

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.reportClosed()
            default: break
            }
        }
        receive()
    }

    func send<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        var framed = data
        framed.append(0x0a)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    func cancel() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            guard self.buffer.count <= 64 * 1024 else {
                self.connection.cancel(); self.reportClosed(); return
            }
            while let newline = self.buffer.firstIndex(of: 0x0a) {
                let lineData = self.buffer[..<newline]
                self.buffer.removeSubrange(...newline)
                if let line = String(data: lineData, encoding: .utf8) { self.onLine?(line) }
            }
            if complete || error != nil { self.reportClosed(); return }
            self.receive()
        }
    }

    private func reportClosed() {
        guard !closed else { return }
        closed = true
        onClosed?()
    }
}

final class LineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""
    func append(_ text: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        partial += text
        let pieces = partial.split(separator: "\n", omittingEmptySubsequences: false)
        partial = pieces.last.map(String.init) ?? ""
        return pieces.dropLast().map(String.init)
    }
}
