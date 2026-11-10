import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func icon(at size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    let tile = CGPath(roundedRect: CGRect(x: 91, y: 91, width: 842, height: 842),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0, 0.08, 0.17, alpha: 0.45))
    context.setFillColor(color(0.05, 0.15, 0.32))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        color(0.04, 0.12, 0.30), color(0.10, 0.26, 0.52), color(0.04, 0.46, 0.54)
    ] as CFArray, locations: [0, 0.53, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 158, y: 186),
                               end: CGPoint(x: 890, y: 916), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let selection = CGRect(x: 254, y: 299, width: 516, height: 426)
    let field = CGPath(roundedRect: selection, cornerWidth: 43, cornerHeight: 43, transform: nil)
    context.setFillColor(color(0.02, 0.10, 0.21, alpha: 0.36))
    context.addPath(field)
    context.fillPath()
    context.setStrokeColor(color(0.67, 0.97, 0.92, alpha: 0.24))
    context.setLineWidth(10)
    context.addPath(field)
    context.strokePath()

    // Four corners echo the selection border drawn by the recorder.
    let inset: CGFloat = 3
    let arm: CGFloat = 118
    let bend: CGFloat = 37
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: inset, y: arm))
    corner.addLine(to: CGPoint(x: inset, y: bend))
    corner.addQuadCurve(to: CGPoint(x: bend, y: inset), control: CGPoint(x: inset, y: inset))
    corner.addLine(to: CGPoint(x: arm, y: inset))
    context.setStrokeColor(color(0.48, 1.0, 0.82))
    context.setLineWidth(45)
    context.setLineCap(.round)
    for (x, sx) in [(selection.minX, CGFloat(1)), (selection.maxX, -1)] {
        for (y, sy) in [(selection.minY, CGFloat(1)), (selection.maxY, -1)] {
            context.saveGState()
            context.translateBy(x: x, y: y)
            context.scaleBy(x: sx, y: sy)
            context.addPath(corner)
            context.strokePath()
            context.restoreGState()
        }
    }

    context.setFillColor(color(1, 0.48, 0.54, alpha: 0.15))
    context.fillEllipse(in: CGRect(x: 400, y: 400, width: 224, height: 224))
    context.setStrokeColor(color(1, 0.69, 0.68, alpha: 0.65))
    context.setLineWidth(10)
    context.strokeEllipse(in: CGRect(x: 421, y: 421, width: 182, height: 182))
    context.setFillColor(color(1, 0.35, 0.40))
    context.fillEllipse(in: CGRect(x: 452, y: 452, width: 120, height: 120))
    context.restoreGState()
    return context.makeImage()!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let url = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, icon(at: points * scale), nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
