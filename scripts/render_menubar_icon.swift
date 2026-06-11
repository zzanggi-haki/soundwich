import AppKit

// Renders the Soundwich menu-bar icon: a sandwich silhouette (domed top bun +
// waveform-filled patty + bottom bun). Outputs a vector PDF template (crisp at any
// menu-bar size) and a PNG preview for review.
//
// Usage: swift render_menubar_icon.swift <out.pdf> <preview.png>

let W: CGFloat = 30
let H: CGFloat = 24

// Per-corner rounded rectangle path.
func roundedPath(_ r: CGRect, tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
    p.move(to: CGPoint(x: minX + tl, y: maxY))
    p.addLine(to: CGPoint(x: maxX - tr, y: maxY))
    p.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY - tr), radius: tr)
    p.addLine(to: CGPoint(x: maxX, y: minY + br))
    p.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX - br, y: minY), radius: br)
    p.addLine(to: CGPoint(x: minX + bl, y: minY))
    p.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX, y: minY + bl), radius: bl)
    p.addLine(to: CGPoint(x: minX, y: maxY - tl))
    p.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX + tl, y: maxY), radius: tl)
    p.closeSubpath()
    return p
}

func draw(into ctx: CGContext, fill: CGColor) {
    ctx.setFillColor(fill)

    // Top bun: wide dome (round top corners, flatter bottom).
    let topBun = roundedPath(CGRect(x: 5, y: 14.2, width: 20, height: 7.8),
                             tl: 5.2, tr: 5.2, br: 2.2, bl: 2.2)
    ctx.addPath(topBun)
    ctx.fillPath()

    // Bottom bun: pill, slightly narrower.
    let bottomBun = roundedPath(CGRect(x: 5.5, y: 2.2, width: 19, height: 3.9),
                                tl: 1.95, tr: 1.95, br: 1.95, bl: 1.95)
    ctx.addPath(bottomBun)
    ctx.fillPath()

    // Middle patty (widest) with a waveform punched out via even-odd fill.
    let pattyRect = CGRect(x: 3, y: 7.6, width: 24, height: 5.4)
    let patty = CGMutablePath()
    patty.addPath(roundedPath(pattyRect, tl: 2.7, tr: 2.7, br: 2.7, bl: 2.7))

    // Waveform: vertical pills of varying height, centered in the patty.
    let fractions: [CGFloat] = [0.30, 0.50, 0.38, 0.72, 0.55, 0.95, 0.55, 0.72, 0.38, 0.50, 0.30]
    let barW: CGFloat = 0.95
    let gap: CGFloat = 0.72
    let maxBarH: CGFloat = pattyRect.height - 1.6
    let total = CGFloat(fractions.count) * barW + CGFloat(fractions.count - 1) * gap
    var x = pattyRect.midX - total / 2
    let midY = pattyRect.midY
    for f in fractions {
        let h = max(barW, maxBarH * f)
        let bar = roundedPath(CGRect(x: x, y: midY - h/2, width: barW, height: h),
                              tl: barW/2, tr: barW/2, br: barW/2, bl: barW/2)
        patty.addPath(bar)
        x += barW + gap
    }
    ctx.addPath(patty)
    ctx.fillPath(using: .evenOdd)
}

// --- PDF (vector template) ---
let pdfURL = URL(fileURLWithPath: CommandLine.arguments[1])
var mediaBox = CGRect(x: 0, y: 0, width: W, height: H)
let pdf = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, nil)!
pdf.beginPDFPage(nil)
draw(into: pdf, fill: NSColor.black.cgColor)
pdf.endPDFPage()
pdf.closePDF()
print("Wrote \(pdfURL.path)")

// --- PNG preview (gray on white, scaled up) ---
let scale: CGFloat = 24
let pw = Int(W * scale), ph = Int(H * scale)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.setShouldAntialias(true)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
ctx.scaleBy(x: scale, y: scale)
draw(into: ctx, fill: NSColor(white: 0.45, alpha: 1).cgColor)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("Wrote \(CommandLine.arguments[2])")
