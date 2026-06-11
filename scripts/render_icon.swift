import AppKit

// Renders the Soundwich app icon master at 1024×1024.
// Concept: a sound waveform "sandwiched" between two bread bars, on a sunset squircle.

let size = 1024.0
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

// --- Squircle background ---
let inset = 88.0
let rect = CGRect(x: inset, y: inset, width: size - inset*2, height: size - inset*2)
let radius = (size - inset*2) * 0.2237   // Apple-ish corner ratio
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

ctx.saveGState()
squircle.addClip()

// Sunset gradient (diagonal, top-left warm → bottom-right pink)
let gradient = NSGradient(colors: [
    color(255, 209, 122),  // warm gold
    color(255, 143, 66),   // orange
    color(255, 99, 99),    // coral
    color(242, 92, 154)    // pink
], atLocations: [0.0, 0.38, 0.7, 1.0], colorSpace: .sRGB)!
gradient.draw(in: rect, angle: -55)

ctx.restoreGState()

// --- Content: two "bread" bars with a waveform between them ---
let cx = size / 2
let white = color(255, 255, 255, 0.96)

// soft shadow for depth
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
              color: color(120, 30, 60, 0.28).cgColor)

func roundedBar(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ fill: NSColor) {
    let r = min(w, h) / 2
    let p = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
    fill.setFill()
    p.fill()
}

// Top bread bar
let breadW = 470.0
let breadH = 46.0
roundedBar(cx - breadW/2, 690, breadW, breadH, white)
// Bottom bread bar
roundedBar(cx - breadW/2, 288, breadW, breadH, white)

// Waveform (equalizer bars) between the bread
ctx.setShadow(offset: .zero, blur: 0, color: nil) // clear shadow for crisp bars
let heights = [150.0, 250.0, 340.0, 250.0, 150.0]
let barW = 52.0
let gap = 34.0
let totalW = Double(heights.count) * barW + Double(heights.count - 1) * gap
var x = cx - totalW/2
let midY = 512.0
for h in heights {
    roundedBar(x, midY - h/2, barW, h, white)
    x += barW + gap
}

NSGraphicsContext.restoreGraphicsState()

// --- Write PNG ---
let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: outURL)
print("Wrote \(outURL.path)")
