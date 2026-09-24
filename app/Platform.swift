import AppKit
import Combine
import CoreGraphics
import CryptoKit
import Network
import ServiceManagement
import SwiftUI
import SystemConfiguration
import VideoToolbox


func wiredIPv4Address(for path: NWPath?) -> String? {
    guard let path, path.usesInterfaceType(.wiredEthernet) else { return nil }
    if case .hostPort(let host, _) = path.localEndpoint {
        let address = String(describing: host)
        if address.contains(".") && !address.contains(":") { return address }
        if let scope = address.split(separator: "%", maxSplits: 1).dropFirst().first,
           let ipv4 = ipv4Address(interfaceName: String(scope)) { return ipv4 }
    }
    guard let interface = path.availableInterfaces.first(where: { $0.type == .wiredEthernet }) else { return nil }
    return ipv4Address(interfaceName: interface.name)
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

func wiredInterfaceNames() -> [String] {
    (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).compactMap { interface -> String? in
        guard SCNetworkInterfaceGetInterfaceType(interface) as String? == kSCNetworkInterfaceTypeEthernet as String else { return nil }
        return SCNetworkInterfaceGetBSDName(interface) as String?
    }.sorted()
}

func activeWiredInterfaces() -> [String] {
    wiredInterfaceNames().compactMap { name in ipv4Address(interfaceName: name).map { "\(name) (\($0))" } }
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
