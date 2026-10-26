import AppKit

func generateIcon() {
    let size: CGFloat = 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // 1. Squircle background (macOS rounded rect style)
    let rect = CGRect(x: 80, y: 80, width: 864, height: 864)
    let path = CGPath(roundedRect: rect, cornerWidth: 200, cornerHeight: 200, transform: nil)

    // Background gradient: Deep slate/navy
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.16, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.06, alpha: 1.0).cgColor
    ] as CFArray
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 944), end: CGPoint(x: 512, y: 80), options: [])
    }

    // Border glow
    ctx.resetClip()
    ctx.addPath(path)
    ctx.setLineWidth(12)
    ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.15).cgColor)
    ctx.strokePath()

    // 2. Gauge Arc
    let center = CGPoint(x: 512, y: 490)
    let radius: CGFloat = 260
    let startAngle: CGFloat = .pi * 0.8
    let endAngle: CGFloat = .pi * 0.2

    // Track background
    let trackPath = CGMutablePath()
    trackPath.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.addPath(trackPath)
    ctx.setLineWidth(44)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.12).cgColor)
    ctx.strokePath()

    // Gauge active arc (cyan to green)
    let activePath = CGMutablePath()
    activePath.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: .pi * 0.45, clockwise: true)
    ctx.addPath(activePath)
    ctx.setLineWidth(44)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.95, alpha: 1.0).cgColor)
    ctx.strokePath()

    // 3. Center Text: "AI"
    let text = "AI" as NSString
    let font = NSFont.systemFont(ofSize: 180, weight: .black)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let textSize = text.size(withAttributes: attrs)
    let textRect = CGRect(
        x: (size - textSize.width) / 2,
        y: center.y - 60,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect, withAttributes: attrs)

    // Subtitle: "METER"
    let sub = "METER" as NSString
    let subFont = NSFont.systemFont(ofSize: 52, weight: .bold)
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: subFont,
        .foregroundColor: NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.70, alpha: 1.0),
        .kern: 6.0
    ]
    let subSize = sub.size(withAttributes: subAttrs)
    let subRect = CGRect(
        x: (size - subSize.width) / 2,
        y: center.y - 130,
        width: subSize.width,
        height: subSize.height
    )
    sub.draw(in: subRect, withAttributes: subAttrs)

    image.unlockFocus()

    // Save iconset
    let fm = FileManager.default
    let iconsetDir = URL(fileURLWithPath: "scripts/AppIcon.iconset")
    try? fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

    let sizes: [(Int, Int, String)] = [
        (16, 1, "icon_16x16.png"),
        (16, 2, "icon_16x16@2x.png"),
        (32, 1, "icon_32x32.png"),
        (32, 2, "icon_32x32@2x.png"),
        (128, 1, "icon_128x128.png"),
        (128, 2, "icon_128x128@2x.png"),
        (256, 1, "icon_256x256.png"),
        (256, 2, "icon_256x256@2x.png"),
        (512, 1, "icon_512x512.png"),
        (512, 2, "icon_512x512@2x.png")
    ]

    for (pt, scale, filename) in sizes {
        let px = pt * scale
        let resized = NSImage(size: NSSize(width: px, height: px))
        resized.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1.0)
        resized.unlockFocus()

        if let tiff = resized.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let fileURL = iconsetDir.appendingPathComponent(filename)
            try? png.write(to: fileURL)
        }
    }
}

generateIcon()
