// Renders the FICTIONAL receipt evaluation set and runs real Vision OCR on it (milestone 5 §M5.6).
//
//   python3 Shared/receipt-eval/build_cases.py
//   swift App/Tools/make-eval-receipts.swift Shared/receipt-eval
//
// For each case in cases.json it writes cases/<id>-p<n>.jpg (the photographed page, with the case's
// degradations: rotation, low contrast, blur, cropping) and cases/<id>.ocr.json: Vision's regions in
// the app's wire format (id, page, order, text, confidence, top-left box, alternatives). Vision runs
// on the Mac here; iOS uses the same recognizer family, so the evidence is representative but not
// identical to a phone's. Everything is invented; nothing here is a real receipt.

import AppKit
import CoreImage
import Foundation
import Vision

struct CaseFile: Decodable {
    struct Case: Decodable {
        let id: String
        let currency: String
        let pages: [[[String?]]]
        let degrade: Degrade
    }

    struct Degrade: Decodable {
        var rotateDegrees: Double?
        var contrast: Double?
        var brightness: Double?
        var blur: Double?
        var cropRight: Double?
    }

    let cases: [Case]
}

struct Region: Encodable {
    let id: String
    let page: Int
    let order: Int
    let text: String
    let confidence: Double
    let box: [Double]
    let alternatives: [String]
}

struct OCRFile: Encodable {
    let id: String
    let likelyCurrency: String
    let pages: [String]
    let regions: [Region]
    let ocrMilliseconds: [Int]
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Shared/receipt-eval")
let output = root.appending(path: "cases")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let file = try JSONDecoder().decode(CaseFile.self, from: Data(contentsOf: root.appending(path: "cases.json")))

let width = 1100.0
let lineHeight = 52.0
let margin = 60.0

func render(_ lines: [[String?]]) -> CGImage {
    let height = margin * 2 + lineHeight * Double(lines.count) + 80
    let canvas = NSSize(width: width + 160, height: height + 160)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height), bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("bitmap") }
    context.cgContext.translateBy(x: 0, y: canvas.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    NSColor(calibratedRed: 0.24, green: 0.25, blue: 0.27, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvas).fill()
    let paper = NSRect(x: 80, y: 80, width: width, height: height)
    NSColor(calibratedRed: 0.985, green: 0.98, blue: 0.965, alpha: 1).setFill()
    paper.fill()
    let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
    var y = paper.minY + margin
    for line in lines {
        let left = line[0] ?? ""
        let right = line.count > 1 ? line[1] : nil
        let style = line.count > 2 ? line[2] ?? "body" : "body"
        let size: CGFloat = style == "title" ? 40 : (style == "center" ? 28 : 32)
        let font = NSFont(name: style == "title" ? "Menlo-Bold" : "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let text = NSAttributedString(string: left, attributes: attributes)
        let x = style == "title" || style == "center" ? paper.midX - text.size().width / 2 : paper.minX + margin
        text.draw(at: NSPoint(x: x, y: y))
        if let right {
            let amount = NSAttributedString(string: right, attributes: attributes)
            amount.draw(at: NSPoint(x: paper.maxX - margin - amount.size().width, y: y))
        }
        y += lineHeight
    }
    NSGraphicsContext.current = nil
    return bitmap.cgImage!
}

let ciContext = CIContext()

func degrade(_ image: CGImage, _ options: CaseFile.Degrade) -> CGImage {
    var result = CIImage(cgImage: image)
    if let degrees = options.rotateDegrees {
        result = result.transformed(by: CGAffineTransform(rotationAngle: degrees * .pi / 180))
        result = result.composited(over: CIImage(color: CIColor(red: 0.24, green: 0.25, blue: 0.27)).cropped(to: result.extent))
    }
    if options.contrast != nil || options.brightness != nil {
        result = result.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: options.contrast ?? 1, kCIInputBrightnessKey: options.brightness ?? 0,
        ])
    }
    if let blur = options.blur {
        result = result.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: result.extent)
    }
    var extent = result.extent
    if let crop = options.cropRight {
        extent.size.width *= (1 - crop)
    }
    return ciContext.createCGImage(result, from: extent)!
}

func jpeg(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

func recognize(_ image: CGImage, page: Int) throws -> [Region] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).enumerated().compactMap { index, observation in
        let candidates = observation.topCandidates(3)
        guard let best = candidates.first else { return nil }
        let box = observation.boundingBox
        return Region(id: UUID().uuidString, page: page, order: index, text: best.string, confidence: Double(best.confidence),
                      box: [box.origin.x, 1 - box.origin.y - box.height, box.width, box.height].map { (Double($0) * 10_000).rounded() / 10_000 },
                      alternatives: candidates.dropFirst().prefix(2).map(\.string))
    }
}

for receipt in file.cases {
    var pageNames: [String] = []
    var regions: [Region] = []
    var timings: [Int] = []
    for (index, lines) in receipt.pages.enumerated() {
        let image = degrade(render(lines), receipt.degrade)
        let name = "\(receipt.id)-p\(index + 1).jpg"
        let data = jpeg(image)
        try data.write(to: output.appending(path: name))
        // OCR the encoded JPEG, exactly what would be stored and sent.
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let started = Date()
        regions += try recognize(decoded, page: index)
        timings.append(Int(Date().timeIntervalSince(started) * 1000))
        pageNames.append(name)
    }
    let ocr = OCRFile(id: receipt.id, likelyCurrency: receipt.currency, pages: pageNames, regions: regions, ocrMilliseconds: timings)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(ocr).write(to: output.appending(path: "\(receipt.id).ocr.json"))
    print("\(receipt.id): \(pageNames.count) page(s), \(regions.count) regions, OCR \(timings.reduce(0, +)) ms")
}
