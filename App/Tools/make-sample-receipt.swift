// Generates the bundled FICTIONAL sample receipt and its prerecorded recognition fixture.
//
//   swift Tools/make-sample-receipt.swift SquareUp/Resources/ReceiptFixtures
//
// Every name, address, phone number, and card fragment is invented (milestone 3 §14, §17.1).
// The image shows the true values. The recognition fixture reproduces the layout exactly but
// contains ONE deliberate misreading — the Tiramisu line reads "6.50" with low confidence — so the
// review step has a realistic correction to make (milestone 3 §20 step 5).

import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let width = 1200.0
let height = 1920.0
let paper = NSRect(x: 150, y: 90, width: 900, height: 1740)
let margin = 56.0
let lineHeight = 58.0

struct Line {
    var left: String
    var right: String?
    var style: Style = .body
    /// What the recognizer "read" for the right column, when it differs (the deliberate error).
    var misreadRight: String?

    enum Style { case title, centered, body, rule }
}

let lines: [Line] = [
    Line(left: "FERNWOOD SUPPER CLUB", style: .title),
    Line(left: "418 Example Ave, Davis CA 95616", style: .centered),
    Line(left: "(530) 555-0136", style: .centered),
    Line(left: "", style: .rule),
    Line(left: "Table 12   Server: Jo   Guests: 4"),
    Line(left: "09/24/2026   7:42 PM"),
    Line(left: "--------------------------------------", style: .rule),
    Line(left: "1 Truffle Fries", right: "9.50"),
    Line(left: "2 Margherita Pizza @ 8.00", right: "16.00"),
    Line(left: "1 Caesar Salad", right: "11.25"),
    Line(left: "2 Lemonade @ 3.50", right: "7.00"),
    Line(left: "1 Mushroom Risotto", right: "18.75"),
    Line(left: "1 Shared Nachos", right: "12.00"),
    Line(left: "1 Tiramisu", right: "8.50", misreadRight: "6.50"),
    Line(left: "1 Iced Tea", right: "3.25"),
    Line(left: "--------------------------------------", style: .rule),
    Line(left: "SUBTOTAL", right: "86.25"),
    Line(left: "Happy Hour Discount", right: "-4.00"),
    Line(left: "Sales Tax 8.25%", right: "6.79"),
    Line(left: "TOTAL", right: "89.04"),
    Line(left: "Tip", right: "15.00"),
    Line(left: "TOTAL", right: "104.04"),
    Line(left: "--------------------------------------", style: .rule),
    Line(left: "VISA ****4821", right: "104.04"),
    Line(left: "AUTH CODE 0A1B2C"),
    Line(left: "", style: .rule),
    Line(left: "Thank you! Come again", style: .centered),
]

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not create bitmap") }
let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
context.cgContext.translateBy(x: 0, y: height)
context.cgContext.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = flipped

// Table surface and paper.
NSColor(calibratedRed: 0.23, green: 0.25, blue: 0.27, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -6)
shadow.set()
NSColor(calibratedRed: 0.985, green: 0.98, blue: 0.965, alpha: 1).setFill()
paper.fill()
NSShadow().set()

let ink = NSColor(calibratedWhite: 0.13, alpha: 1)
func font(_ style: Line.Style) -> NSFont {
    switch style {
    case .title: NSFont(name: "Menlo-Bold", size: 44) ?? .monospacedSystemFont(ofSize: 44, weight: .bold)
    case .centered: NSFont(name: "Menlo-Regular", size: 30) ?? .monospacedSystemFont(ofSize: 30, weight: .regular)
    case .body, .rule: NSFont(name: "Menlo-Regular", size: 34) ?? .monospacedSystemFont(ofSize: 34, weight: .regular)
    }
}

struct Region: Encodable {
    let text: String
    let confidence: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var alternatives: [String]?
}

var regions: [Region] = []
var y = paper.minY + 70

func draw(_ text: String, style: Line.Style, at point: NSPoint) -> NSRect {
    let attributes: [NSAttributedString.Key: Any] = [.font: font(style), .foregroundColor: ink]
    let string = NSAttributedString(string: text, attributes: attributes)
    string.draw(at: point)
    let size = string.size()
    return NSRect(origin: point, size: size)
}

func record(_ text: String, _ rect: NSRect, confidence: Double = 1.0, alternatives: [String]? = nil) {
    // Tight vertical box around the glyphs, like a recognizer reports.
    let inset = rect.height * 0.12
    regions.append(Region(
        text: text, confidence: confidence,
        x: (rect.minX / width * 10_000).rounded() / 10_000, y: ((rect.minY + inset) / height * 10_000).rounded() / 10_000,
        width: (rect.width / width * 10_000).rounded() / 10_000, height: ((rect.height - 2 * inset) / height * 10_000).rounded() / 10_000,
        alternatives: alternatives
    ))
}

for line in lines {
    let lineFont = font(line.style)
    switch line.style {
    case .rule:
        if !line.left.isEmpty {
            let rect = draw(line.left, style: .rule, at: NSPoint(x: paper.minX + margin, y: y))
            record(line.left, rect, confidence: 0.6)
        }
    case .title, .centered:
        let size = NSAttributedString(string: line.left, attributes: [.font: lineFont]).size()
        let rect = draw(line.left, style: line.style, at: NSPoint(x: paper.midX - size.width / 2, y: y))
        record(line.left, rect)
    case .body:
        let rect = draw(line.left, style: .body, at: NSPoint(x: paper.minX + margin, y: y))
        record(line.left, rect)
        if let right = line.right {
            let size = NSAttributedString(string: right, attributes: [.font: lineFont]).size()
            let rightRect = draw(right, style: .body, at: NSPoint(x: paper.maxX - margin - size.width, y: y))
            if let misread = line.misreadRight {
                record(misread, rightRect, confidence: 0.42, alternatives: [right])
            } else {
                record(right, rightRect)
            }
        }
    }
    y += line.style == .title ? lineHeight + 14 : lineHeight
}

NSGraphicsContext.current = nil
guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else { fatalError("JPEG encoding failed") }
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try jpeg.write(to: outputDirectory.appending(path: "fernwood-dinner.jpg"))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
struct Fixture: Encodable {
    let note = "FICTIONAL sample receipt. Prerecorded recognition with one deliberate misreading (Tiramisu 8.50 read as 6.50)."
    let regions: [Region]
}

try encoder.encode(Fixture(regions: regions)).write(to: outputDirectory.appending(path: "fernwood-dinner.json"))
print("Wrote \(regions.count) regions and a \(Int(width))×\(Int(height)) image to \(outputDirectory.path)")
