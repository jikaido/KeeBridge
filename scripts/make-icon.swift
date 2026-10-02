// Draws the half KeePassXC, half compass icon. Everything is drawn here except the KeePassXC
// key, which is upstream/icons/keepassxc.svg (GPL, shipped with KeePassXC-Browser).
// No installed app icons are used.
// Usage: swift scripts/make-icon.swift [preview.png]
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let xcode = root.appendingPathComponent("xcode/KeeBridge")
let appIconSet = xcode.appendingPathComponent("KeeBridge/Assets.xcassets/AppIcon.appiconset")
let extensionIcons = xcode.appendingPathComponent("KeeBridge Extension/Resources/icons")
let keySVG = root.appendingPathComponent("upstream/icons/keepassxc.svg")
guard let keepass = NSImage(contentsOf: keySVG) else { fatalError("Cannot load \(keySVG.path)") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// macOS app icon grid on a 1024 canvas: the shape is inset 100 (about 10%), so it is 824 wide.
let canvas = 1024.0
let shapeRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let center = NSPoint(x: canvas / 2, y: canvas / 2)

// Rounded square with continuous (squircle) corners. Each corner is a quarter superellipse that
// meets the straight edges with zero curvature, sized so it reads like a 22.5% corner radius.
func squircle(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    let extent = min(radius * 1.6, rect.width / 2)
    let exponent = 3.6
    let path = NSBezierPath()
    // Corner centres and the quadrant each one covers, counterclockwise from the lower right.
    let corners: [(NSPoint, CGFloat)] = [
        (NSPoint(x: rect.maxX - extent, y: rect.minY + extent), -.pi / 2),
        (NSPoint(x: rect.maxX - extent, y: rect.maxY - extent), 0),
        (NSPoint(x: rect.minX + extent, y: rect.maxY - extent), .pi / 2),
        (NSPoint(x: rect.minX + extent, y: rect.minY + extent), .pi),
    ]
    for (corner, start) in corners {
        for step in 0...48 {
            let t = start + .pi / 2 * CGFloat(step) / 48
            let c = cos(t), s = sin(t)
            let x = corner.x + extent * copysign(pow(abs(c), 2 / exponent), c)
            let y = corner.y + extent * copysign(pow(abs(s), 2 / exponent), s)
            if path.isEmpty { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
        }
    }
    path.close()
    return path
}

func circle(_ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
}

func point(_ angle: CGFloat, _ r: CGFloat) -> NSPoint {
    NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
}

// Shadows ignore the transform, so blur and offset are scaled to the output size by hand.
func withShadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let scale = NSGraphicsContext.current!.cgContext.ctm.a
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur * scale
    shadow.shadowOffset = NSSize(width: 0, height: -dy * scale)
    shadow.shadowColor = NSColor(white: 0, alpha: alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// The detailed dial matches the geometry of keepassxc.svg (a 100 unit circle drawn `svgWidth`
// points wide): a dark rim out to 47.5 units, a light band, and the coloured face inside 37 units.
// The simple dial for small sizes drops the light band so the face and the key are larger.
struct Dial {
    let svgWidth: CGFloat, rimOuter: CGFloat, bandOuter: CGFloat, faceRadius: CGFloat, ticks: Bool
    static let detailed = Dial(svgWidth: 660, rimOuter: 47.5 * 6.6, bandOuter: 44.37 * 6.6,
                               faceRadius: 37 * 6.6, ticks: true)
    static let simple = Dial(svgWidth: 330 / 0.37, rimOuter: 358, bandOuter: 330, faceRadius: 330,
                             ticks: false)
}

func drawBackground() {
    let shape = squircle(shapeRect, radius: shapeRect.width * 0.225)
    withShadow(28, 12, 0.35) { color(0xFFFFFF).setFill(); shape.fill() }
    NSGradient(starting: color(0xFFFFFF), ending: color(0xE3E6EB))!.draw(in: shape, angle: -90)
    // Hairline edge so the light shape holds up on a white background.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    color(0x000000, 0.08).setStroke()
    shape.lineWidth = 4
    shape.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

// The rim and band match keepassxc.svg drawn over white (its rim is black at 0.784 opacity
// inside a group at 0.871), so the halves meet cleanly.
let rimColor = color(0x000000, 0.871 * 0.784), bandColor = color(0xF9F9F9)

func drawCompass(_ dial: Dial) {
    withShadow(18, 8, 0.3) { color(0xFFFFFF).setFill(); circle(dial.rimOuter).fill() }
    rimColor.setFill()
    circle(dial.rimOuter).fill()
    // The svg's band is white for its outer 0.7 units, then #F9F9F9.
    color(0xFFFFFF).setFill()
    circle(dial.bandOuter).fill()
    bandColor.setFill()
    circle(dial.bandOuter - 0.7 * dial.svgWidth / 100).fill()
    let face = circle(dial.faceRadius)
    NSGradient(colors: [color(0x6FD6FF), color(0x1A8CFF), color(0x0B55D9)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: face, relativeCenterPosition: NSPoint(x: 0, y: 0.35))
    guard dial.ticks else { return }
    // Ticks: a long one every 30 degrees, short ones every 6 degrees in between.
    NSGraphicsContext.saveGraphicsState()
    face.addClip()
    for i in 0..<60 {
        let angle = CGFloat(i) * .pi / 30
        let major = i % 5 == 0
        let tick = NSBezierPath()
        tick.move(to: point(angle, dial.faceRadius * (major ? 0.78 : 0.86)))
        tick.line(to: point(angle, dial.faceRadius * 0.95))
        tick.lineWidth = major ? 9 : 5
        tick.lineCapStyle = .round
        color(0xFFFFFF, major ? 0.9 : 0.6).setStroke()
        tick.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
}

// The KeePassXC half: the upper left triangle, so the seam follows the needle. The svg's ring is
// translucent, so it goes over a white disc rather than over the compass rim.
func drawKey(_ dial: Dial) {
    NSGraphicsContext.saveGraphicsState()
    let triangle = NSBezierPath()
    triangle.move(to: .zero)
    triangle.line(to: NSPoint(x: canvas, y: canvas))
    triangle.line(to: NSPoint(x: 0, y: canvas))
    triangle.close()
    triangle.addClip()
    if dial.ticks {
        color(0xFFFFFF).setFill()
        circle(dial.rimOuter).fill()
    } else {
        // The simple dial keeps its own rim and shows only the svg's green face.
        circle(dial.faceRadius).addClip()
        color(0xFFFFFF).setFill()
        circle(dial.faceRadius).fill()
    }
    let w = dial.svgWidth
    keepass.draw(in: NSRect(x: center.x - w / 2, y: center.y - w / 2, width: w, height: w))
    NSGraphicsContext.restoreGraphicsState()
}

// Two-tone needle along the diagonal: red tip to the upper right, white tail to the lower left.
// Each half is split lengthwise into a light and a dark facet.
func drawNeedle(length: CGFloat, width: CGFloat, pin: Bool) {
    let tipAngle = CGFloat.pi / 4
    let tip = point(tipAngle, length), tail = point(tipAngle + .pi, length)
    let left = point(tipAngle + .pi / 2, width / 2), right = point(tipAngle - .pi / 2, width / 2)
    func facet(_ a: NSPoint, _ b: NSPoint, _ fill: NSColor) {
        let path = NSBezierPath()
        path.move(to: center)
        path.line(to: a)
        path.line(to: b)
        path.close()
        fill.setFill()
        path.fill()
    }
    withShadow(14, 6, 0.35) {
        let outline = NSBezierPath()
        outline.move(to: tip); outline.line(to: left); outline.line(to: tail); outline.line(to: right)
        outline.close()
        color(0xFFFFFF).setFill()
        outline.fill()
    }
    facet(tip, left, color(0xFF4A3D))
    facet(tip, right, color(0xC8102E))
    facet(tail, left, color(0xFFFFFF))
    facet(tail, right, color(0xD5DAE1))
    guard pin else { return }
    let hub = circle(width * 0.22)
    color(0xFFFFFF).setFill()
    hub.fill()
    color(0x9AA3AE).setStroke()
    hub.lineWidth = 3
    hub.stroke()
}

func drawIcon(_ dial: Dial) {
    drawBackground()
    drawCompass(dial)
    drawKey(dial)
    // Redraw the whole rim so antialiasing at the seam leaves no light notch in it.
    NSGraphicsContext.saveGraphicsState()
    let rim = circle(dial.rimOuter)
    rim.append(circle(dial.bandOuter))
    rim.windingRule = .evenOdd
    rim.addClip()
    color(0xFFFFFF).setFill()
    circle(dial.rimOuter).fill()
    rimColor.setFill()
    circle(dial.rimOuter).fill()
    NSGraphicsContext.restoreGraphicsState()
    if dial.ticks {
        drawNeedle(length: dial.faceRadius * 0.92, width: 70, pin: true)
    } else {
        drawNeedle(length: dial.faceRadius * 0.9, width: 120, pin: false)
    }
}

func render(_ pixels: Int, from source: NSRect = NSRect(x: 0, y: 0, width: canvas, height: canvas),
            _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / source.width
    context.cgContext.scaleBy(x: scale, y: scale)
    context.cgContext.translateBy(x: -source.minX, y: -source.minY)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Each size is drawn as vectors, so edges stay crisp. Below 64 pixels the simple dial is used.
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let png = render(pixels) { drawIcon(pixels >= 64 ? .detailed : .simple) }
        try png.write(to: appIconSet.appendingPathComponent("mac-icon-\(size)@\(scale)x.png"))
    }
}

// Extension icons drop the icon grid margin so the shape fills the canvas like other extension icons.
for size in [16, 18, 19, 32, 36, 38, 48, 64, 96, 128] {
    let png = render(size, from: shapeRect) { drawIcon(size >= 64 ? .detailed : .simple) }
    try png.write(to: extensionIcons.appendingPathComponent("safari_\(size)x\(size).png"))
}

if CommandLine.arguments.count > 1 {
    try render(1024) { drawIcon(.detailed) }.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print("Wrote \(appIconSet.path) and \(extensionIcons.path)/safari_*.png")
