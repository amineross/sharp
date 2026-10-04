import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Network
import ServiceManagement
import SwiftUI
import SystemConfiguration
import VideoToolbox


enum SharpLinkKind: String {
    case ethernet = "Ethernet"
    case thunderbolt = "Thunderbolt"
}

/// A cable Sharp may stream over: a wired Ethernet adapter or Thunderbolt Bridge.
struct SharpDirectInterface: Equatable {
    let name: String
    let displayName: String
    let kind: SharpLinkKind
}

/// Thunderbolt networking appears as a bridge (bridge0) whose members are the
/// Thunderbolt ports. Those member ports report as Ethernet but never carry an
/// address, so they drop out once an IPv4 address is required.
func directInterfaces() -> [SharpDirectInterface] {
    (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { interface -> SharpDirectInterface? in
        guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
              let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { return nil }
        let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? name
        // kSCNetworkInterfaceTypeBridge is not in the public SDK. Every
        // localization of "Thunderbolt Bridge" keeps the brand name.
        if type == "Bridge" {
            return SharpDirectInterface(name: name, displayName: displayName,
                                        kind: displayName.contains("Thunderbolt") ? .thunderbolt : .ethernet)
        }
        // iPhone and iPad tethering also report as Ethernet.
        guard type == kSCNetworkInterfaceTypeEthernet as String,
              !displayName.hasPrefix("iPhone"), !displayName.hasPrefix("iPad") else { return nil }
        return SharpDirectInterface(name: name, displayName: displayName, kind: .ethernet)
    }.sorted { $0.name < $1.name }
}

func directInterface(named name: String?) -> SharpDirectInterface? {
    guard let name else { return nil }
    return directInterfaces().first { $0.name == name }
}

/// Direct interfaces with an IPv4 address, Thunderbolt first.
func activeDirectInterfaces() -> [(interface: SharpDirectInterface, address: String)] {
    directInterfaces().compactMap { interface in ipv4Address(interfaceName: interface.name).map { (interface, $0) } }
        .sorted { ($0.interface.kind == .thunderbolt ? 0 : 1, $0.interface.name) < ($1.interface.kind == .thunderbolt ? 0 : 1, $1.interface.name) }
}

func activeDirectSummary() -> [String] {
    activeDirectInterfaces().map { "\($0.interface.name) \($0.interface.displayName) (\($0.address))" }
}

/// This Mac's IPv4 address on the path, if the path runs over a direct interface.
func directIPv4Address(for path: NWPath?) -> String? {
    guard let path else { return nil }
    let direct = Set(directInterfaces().map(\.name))
    if case .hostPort(let host, _)? = path.localEndpoint {
        let parts = String(describing: host).split(separator: "%", maxSplits: 1).map(String.init)
        if let address = parts.first, address.contains("."), !address.contains(":") {
            if let name = interfaceName(forIPv4: address), direct.contains(name) { return address }
        } else if parts.count == 2, direct.contains(parts[1]), let ipv4 = ipv4Address(interfaceName: parts[1]) {
            return ipv4
        }
    }
    guard let interface = path.availableInterfaces.first(where: { direct.contains($0.name) }) else { return nil }
    return ipv4Address(interfaceName: interface.name)
}

/// Negotiated link speed in bits per second; nil when the driver does not report one.
func linkSpeed(interfaceName: String) -> UInt64? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
    defer { freeifaddrs(pointer) }
    for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard String(cString: item.pointee.ifa_name) == interfaceName,
              item.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
              let data = item.pointee.ifa_data else { continue }
        let speed = UInt64(data.assumingMemoryBound(to: if_data.self).pointee.ifi_baudrate)
        return speed > 0 ? speed : nil
    }
    return nil
}

func interfaceName(forIPv4 address: String) -> String? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
    defer { freeifaddrs(pointer) }
    for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard item.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(item.pointee.ifa_addr, socklen_t(item.pointee.ifa_addr.pointee.sa_len),
                       &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
           String(cString: host) == address {
            return String(cString: item.pointee.ifa_name)
        }
    }
    return nil
}

func sharpPairingCode(_ first: String, _ second: String) -> String {
    let joined = [first, second].sorted().joined(separator: ":")
    let digest = SHA256.hash(data: Data(joined.utf8))
    let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
    return String(format: "%06u", number)
}

func h264HardwareEncoderAvailable(width: Int, height: Int) -> Bool {
    var session: VTCompressionSession?
    let specification = [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
    ] as CFDictionary
    let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
                                             width: Int32(width), height: Int32(height),
                                             codecType: kCMVideoCodecType_H264,
                                             encoderSpecification: specification,
                                             imageBufferAttributes: nil,
                                             compressedDataAllocator: nil,
                                             outputCallback: nil,
                                             refcon: nil,
                                             compressionSessionOut: &session)
    if let session { VTCompressionSessionInvalidate(session) }
    return status == noErr
}

func receiverDisplaySize() -> SharpDisplaySize {
    let display = CGMainDisplayID()
    return SharpDisplaySize(width: max(640, CGDisplayPixelsWide(display)),
                            height: max(360, CGDisplayPixelsHigh(display)))
}

var sharpVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
}

func ipv4Address(interfaceName: String) -> String? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
    defer { freeifaddrs(pointer) }
    for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(item.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
              item.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: item.pointee.ifa_name)
        guard name == interfaceName else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(item.pointee.ifa_addr.pointee.sa_len)
        if getnameinfo(item.pointee.ifa_addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            return String(cString: host)
        }
    }
    return nil
}
