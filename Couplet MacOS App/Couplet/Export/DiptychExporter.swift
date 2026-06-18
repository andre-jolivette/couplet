import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - Options

enum ExportLayout: String, CaseIterable, Sendable {
    case horizontal = "Horizontal"
    case vertical   = "Vertical"
}

enum ExportBackground: String, CaseIterable, Sendable {
    case white = "White"
    case black = "Black"

    nonisolated var cgColor: CGColor {
        switch self {
        case .white: return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .black: return CGColor(
            red: 0x0e / 255.0, green: 0x0e / 255.0, blue: 0x10 / 255.0, alpha: 1
        )
        }
    }

    nonisolated var labelColor: CGColor {
        switch self {
        case .white: return CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
        case .black: return CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
        }
    }
}

struct DiptychExportOptions: Sendable {
    var includeFilenames: Bool
    var layout: ExportLayout      = .horizontal
    var background: ExportBackground = .white
}

// MARK: - Exporter

/// Pure rendering struct: takes two CGImages, returns JPEG or PDF data.
/// All methods are thread-safe and can be called from a background Task.
struct DiptychExporter: Sendable {

    let cgImageA: CGImage
    let cgImageB: CGImage
    let filenameA: String
    let filenameB: String
    let options: DiptychExportOptions

    // MARK: - Public API

    nonisolated func jpegData(quality: CGFloat = 0.92) -> Data? {
        guard let canvas = renderCanvas() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, canvas,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    nonisolated func pdfData() -> Data? {
        guard let canvas = renderCanvas() else { return nil }
        let pxW = CGFloat(canvas.width)
        let pxH = CGFloat(canvas.height)
        // Target 300 dpi: 1 PDF point = 1/72 inch, so 1px = 72/300 pt
        let ptW = (pxW * 72.0 / 300.0).rounded()
        let ptH = (pxH * 72.0 / 300.0).rounded()
        var pageRect = CGRect(x: 0, y: 0, width: ptW, height: ptH)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &pageRect, nil)
        else { return nil }

        ctx.beginPDFPage(nil)
        ctx.draw(canvas, in: pageRect)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    // MARK: - Canvas rendering

    nonisolated func renderCanvas() -> CGImage? {
        switch options.layout {
        case .horizontal: return renderHorizontal()
        case .vertical:   return renderVertical()
        }
    }

    private nonisolated func renderHorizontal() -> CGImage? {
        let wA = CGFloat(cgImageA.width), hA = CGFloat(cgImageA.height)
        let wB = CGFloat(cgImageB.width), hB = CGFloat(cgImageB.height)

        var slotW = max(wA, wB)
        var slotH = max(hA, hB)

        let longEdge = max(slotW, slotH)
        if longEdge > 6000 {
            let f = 6000 / longEdge
            slotW = (slotW * f).rounded()
            slotH = (slotH * f).rounded()
        }

        let outerPad = (slotH * 0.040).rounded()
        let gap      = max(20, (slotH * 0.025).rounded())
        let labelH   = options.includeFilenames ? (slotH * 0.045).rounded() : 0

        let canvasW = (outerPad * 2 + slotW * 2 + gap).rounded()
        let canvasH = (outerPad * 2 + slotH + labelH).rounded()

        guard let ctx = CGContext(
            data: nil,
            width: Int(canvasW), height: Int(canvasH),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(options.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        // In CGContext coords (y=0 at bottom):
        //   bottom border: 0 … outerPad
        //   label strip:   outerPad … outerPad+labelH
        //   image area:    outerPad+labelH … outerPad+labelH+slotH
        //   top border:    outerPad+labelH+slotH … canvasH
        let imageY    = outerPad + labelH
        let leftSlot  = CGRect(x: outerPad,               y: imageY, width: slotW, height: slotH)
        let rightSlot = CGRect(x: outerPad + slotW + gap, y: imageY, width: slotW, height: slotH)
        letterbox(cgImageA, pixelW: wA, pixelH: hA, into: ctx, slot: leftSlot)
        letterbox(cgImageB, pixelW: wB, pixelH: hB, into: ctx, slot: rightSlot)

        if options.includeFilenames {
            let fontSize = max(12, (slotH * 0.016).rounded())
            let labelColor = options.background.labelColor
            drawLabel(filenameA, in: ctx,
                      rect: CGRect(x: outerPad, y: outerPad, width: slotW, height: labelH),
                      fontSize: fontSize, color: labelColor)
            drawLabel(filenameB, in: ctx,
                      rect: CGRect(x: outerPad + slotW + gap, y: outerPad, width: slotW, height: labelH),
                      fontSize: fontSize, color: labelColor)
        }

        return ctx.makeImage()
    }

    private nonisolated func renderVertical() -> CGImage? {
        let wA = CGFloat(cgImageA.width), hA = CGFloat(cgImageA.height)
        let wB = CGFloat(cgImageB.width), hB = CGFloat(cgImageB.height)

        var slotW = max(wA, wB)
        var slotH = max(hA, hB)

        let longEdge = max(slotW, slotH)
        if longEdge > 6000 {
            let f = 6000 / longEdge
            slotW = (slotW * f).rounded()
            slotH = (slotH * f).rounded()
        }

        let outerPad = (slotW * 0.040).rounded()
        let gap      = max(20, (slotW * 0.025).rounded())
        let labelH   = options.includeFilenames ? (slotW * 0.028).rounded() : 0

        let canvasW = (outerPad * 2 + slotW).rounded()
        let canvasH = (outerPad * 2 + slotH * 2 + gap + labelH * 2).rounded()

        guard let ctx = CGContext(
            data: nil,
            width: Int(canvasW), height: Int(canvasH),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(options.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        // In CGContext coords (y=0 at bottom):
        //   bottom border:    0 … outerPad
        //   bottom label:     outerPad … outerPad+labelH
        //   bottom image (B): outerPad+labelH … outerPad+labelH+slotH
        //   gap:              outerPad+labelH+slotH … outerPad+labelH+slotH+gap
        //   top label (A):    outerPad+labelH+slotH+gap … outerPad+labelH*2+slotH+gap
        //   top image (A):    outerPad+labelH*2+slotH+gap … outerPad+labelH*2+slotH*2+gap
        //   top border:       … canvasH
        let topImageY    = outerPad + labelH * 2 + slotH + gap
        let bottomImageY = outerPad + labelH
        let topSlot    = CGRect(x: outerPad, y: topImageY,    width: slotW, height: slotH)
        let bottomSlot = CGRect(x: outerPad, y: bottomImageY, width: slotW, height: slotH)
        letterbox(cgImageA, pixelW: wA, pixelH: hA, into: ctx, slot: topSlot)
        letterbox(cgImageB, pixelW: wB, pixelH: hB, into: ctx, slot: bottomSlot)

        if options.includeFilenames {
            let fontSize = max(10, (slotW * 0.013).rounded())
            let labelColor = options.background.labelColor
            // Label A sits just above top image (inside the gap area, right at bottom of top image)
            let topLabelY    = outerPad + labelH + slotH + gap
            let bottomLabelY = outerPad
            drawLabel(filenameA, in: ctx,
                      rect: CGRect(x: outerPad, y: topLabelY, width: slotW, height: labelH),
                      fontSize: fontSize, color: labelColor)
            drawLabel(filenameB, in: ctx,
                      rect: CGRect(x: outerPad, y: bottomLabelY, width: slotW, height: labelH),
                      fontSize: fontSize, color: labelColor)
        }

        return ctx.makeImage()
    }

    // MARK: - Helpers

    /// Scale image to fit slot (never upscale), center with white letterbox fill.
    private nonisolated func letterbox(
        _ image: CGImage, pixelW: CGFloat, pixelH: CGFloat,
        into ctx: CGContext, slot: CGRect
    ) {
        // Compute scale — cap at 1.0 so we never magnify beyond native pixels
        let scale = min(slot.width / pixelW, slot.height / pixelH, 1.0)
        let drawW = (pixelW * scale).rounded()
        let drawH = (pixelH * scale).rounded()
        let drawX = (slot.minX + (slot.width  - drawW) / 2).rounded()
        let drawY = (slot.minY + (slot.height - drawH) / 2).rounded()
        ctx.draw(image, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
    }

    /// Draw a single line of text left-aligned and vertically centered in rect.
    private nonisolated func drawLabel(
        _ text: String, in ctx: CGContext,
        rect: CGRect, fontSize: CGFloat, color: CGColor
    ) {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let setter  = CTFramesetterCreateWithAttributedString(attrStr)

        // Measure the line height so we can vertically center it
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRangeMake(0, 0), nil,
            CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil
        )
        let textY = (rect.minY + (rect.height - textSize.height) / 2).rounded()
        let textRect = CGRect(x: rect.minX, y: textY,
                              width: rect.width, height: textSize.height + 2)

        let path  = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, ctx)
    }
}
