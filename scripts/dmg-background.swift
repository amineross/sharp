import AppKit

let size = NSSize(width: 720, height: 440)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedWhite: 0.87, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
let path = NSBezierPath()
path.lineWidth = 2
path.lineCapStyle = .round
path.move(to: NSPoint(x: 331, y: 212))
path.line(to: NSPoint(x: 389, y: 212))
path.move(to: NSPoint(x: 379, y: 221))
path.line(to: NSPoint(x: 389, y: 212))
path.line(to: NSPoint(x: 379, y: 203))
NSColor(calibratedWhite: 0.28, alpha: 1).setStroke()
path.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
