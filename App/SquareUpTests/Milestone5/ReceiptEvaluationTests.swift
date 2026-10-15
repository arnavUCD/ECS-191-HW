import Foundation
@testable import SquareUp
import Testing

// Milestone 5 §12: compares the deterministic parser, Claude's proposal, and the hybrid result on
// the fictional set in HW/Shared/receipt-eval. Vision's evidence comes from real OCR of the generated
// images (App/Tools/make-eval-receipts.swift). Claude's answers are read from
// Shared/receipt-eval/results/claude, written by the opt-in live runner
// (server/scripts/run_receipt_eval.py); without them only the deterministic column is measured.
// The report is attached to the test and written to Shared/receipt-eval/results/report.md.

private enum Eval {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../Shared/receipt-eval").standardized

    struct CaseFile: Decodable {
        let cases: [Case]
    }

    struct Case: Decodable {
        let id: String
        let tags: [String]
        let currency: String
        let truth: Truth
        let expectReconciled: Bool
    }

    struct Truth: Decodable {
        struct Item: Decodable {
            let name: String
            let amount: String
        }

        struct Charge: Decodable {
            let kind: String
            let amount: String
        }

        let merchant: String
        let date: String
        let currency: String
        let items: [Item]
        let charges: [Charge]
        let total: String
    }

    struct OCRFile: Decodable {
        struct Region: Decodable {
            let id: String
            let page: Int
            let order: Int
            let text: String
            let confidence: Double
            let box: [Double]
            let alternatives: [String]
        }

        let pages: [String]
        let regions: [Region]
        let ocrMilliseconds: [Int]
    }

    struct ClaudeSummary: Decodable {
        struct Run: Decodable {
            let id: String
            let outcome: String
            let latencyMs: Double
            let inputTokens: Int
            let outputTokens: Int
        }

        let model: String
        let inputPricePerMTok: Double
        let outputPricePerMTok: Double
        let runs: [Run]
    }
}

/// Scores for one strategy on one receipt.
private struct Score {
    var merchant = false, date = false, currency = false, total = false
    var truthItems = 0, itemAmounts = 0, itemNames = 0, spuriousItems = 0
    var truthCharges = 0, charges = 0, spuriousCharges = 0
    var reconciledAsExpected = false
    var silentErrors = 0
    var failed = false
    var corrections: Int {
        [merchant, date, currency, total].filter { !$0 }.count + (truthItems - itemAmounts) + (itemAmounts - itemNames) + spuriousItems
            + (truthCharges - charges) + spuriousCharges
    }
}

private func normalized(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
}

private func tokens(_ text: String) -> Set<String> {
    Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
}

private func nameMatches(_ predicted: String, _ truth: String) -> Bool {
    let expected = tokens(truth)
    guard !expected.isEmpty else { return normalized(predicted) == normalized(truth) }
    return Double(expected.intersection(tokens(predicted)).count) / Double(expected.count) >= 0.6
}

private func score(_ draft: ReceiptDraft?, truth: Eval.Truth, expectReconciled: Bool) -> Score {
    var score = Score()
    score.truthItems = truth.items.count
    score.truthCharges = truth.charges.count
    guard let draft, !(draft.items.isEmpty && draft.total.value == nil) else {
        score.failed = true
        return score
    }
    let currency = CurrencyCode(truth.currency)
    func money(_ text: String) -> Money? { ReceiptAmountParser.parse(text, currency: currency)?.money }
    let merchant = normalized(draft.merchant.value), expectedMerchant = normalized(truth.merchant)
    score.merchant = !merchant.isEmpty && (merchant == expectedMerchant || (merchant.count >= 4 && expectedMerchant.contains(merchant))
        || (expectedMerchant.count >= 4 && merchant.contains(expectedMerchant)))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let parts = calendar.dateComponents([.year, .month, .day], from: draft.date.value)
    score.date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) == truth.date && draft.date.reason != .notFound
    score.currency = draft.currencyCode == currency
    score.total = draft.total.value == money(truth.total)
    if !score.merchant, draft.merchant.attention == .looksGood { score.silentErrors += 1 }
    if !score.date, draft.date.attention == .looksGood { score.silentErrors += 1 }
    if !score.total, draft.total.attention == .looksGood { score.silentErrors += 1 }

    var remaining = draft.items
    for item in truth.items {
        guard let amount = money(item.amount) else { continue }
        let candidates = remaining.indices.filter { remaining[$0].amount == amount }
        guard let best = candidates.first(where: { nameMatches(remaining[$0].name.value, item.name) }) ?? candidates.first else { continue }
        score.itemAmounts += 1
        if nameMatches(remaining[best].name.value, item.name) { score.itemNames += 1 }
        remaining.remove(at: best)
    }
    score.spuriousItems = remaining.count(where: { !$0.amount.isZero })
    score.silentErrors += remaining.count(where: { !$0.amount.isZero && $0.attention == .looksGood })

    var charges = draft.charges
    for charge in truth.charges {
        guard let amount = money(charge.amount), let index = charges.firstIndex(where: { $0.kind.rawValue == charge.kind && $0.value == amount })
        else { continue }
        score.charges += 1
        charges.remove(at: index)
    }
    score.spuriousCharges = charges.count
    score.silentErrors += charges.count(where: { $0.amount.attention == .looksGood })
    score.reconciledAsExpected = ReceiptValidator.reconcile(draft).isReconciled == expectReconciled
    return score
}

private struct Totals {
    var cases = 0, merchant = 0, date = 0, currency = 0, total = 0
    var truthItems = 0, itemAmounts = 0, itemNames = 0, truthCharges = 0, charges = 0
    var reconciled = 0, corrections = 0, silentErrors = 0, failures = 0, fallbacks = 0

    mutating func add(_ score: Score) {
        cases += 1
        merchant += score.merchant ? 1 : 0
        date += score.date ? 1 : 0
        currency += score.currency ? 1 : 0
        total += score.total ? 1 : 0
        truthItems += score.truthItems
        itemAmounts += score.itemAmounts
        itemNames += score.itemNames
        truthCharges += score.truthCharges
        charges += score.charges
        reconciled += score.reconciledAsExpected ? 1 : 0
        corrections += score.corrections
        silentErrors += score.silentErrors
        failures += score.failed ? 1 : 0
    }

    func percent(_ part: Int, _ whole: Int) -> String { whole == 0 ? "–" : "\(Int((Double(part) / Double(whole) * 100).rounded()))%" }

    func row(_ name: String) -> String {
        "| \(name) | \(cases) | \(percent(merchant, cases)) | \(percent(date, cases)) | \(percent(currency, cases)) | \(percent(itemNames, truthItems)) "
            + "| \(percent(itemAmounts, truthItems)) | \(percent(charges, truthCharges)) | \(percent(total, cases)) | \(percent(reconciled, cases)) "
            + "| \(corrections) | \(silentErrors) | \(percent(failures, cases)) | \(percent(fallbacks, cases)) |"
    }
}

@Suite("Receipt evaluation (fictional set)")
struct ReceiptEvaluationTests {
    private func load<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
        (try? Data(contentsOf: Eval.directory.appending(path: path))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func input(_ ocr: Eval.OCRFile, currency: CurrencyCode, seed: UUID) -> ReceiptStructuringInput {
        let pages = ocr.pages.indices.map { ReceiptFixtures.page(ReceiptAssetID(DerivedID.make(seed, 900 + $0))) }
        let regions = ocr.regions.compactMap { wire -> RecognizedRegion? in
            guard let id = UUID(uuidString: wire.id), pages.indices.contains(wire.page), wire.box.count == 4 else { return nil }
            return RecognizedRegion(id: ReceiptRegionID(id), pageID: pages[wire.page].id, text: wire.text, confidence: wire.confidence,
                                    bounds: ReceiptRect(x: wire.box[0], y: wire.box[1], width: wire.box[2], height: wire.box[3]),
                                    alternatives: wire.alternatives, readingOrder: wire.order)
        }
        return ReceiptStructuringInput(pages: pages, regions: regions, defaultCurrency: currency, captureDate: DemoScenario.fixedReferenceDate,
                                       idSeed: seed, timeZone: .gmt)
    }

    private func draft(_ proposal: ReceiptProposal, input: ReceiptStructuringInput) -> ReceiptDraft {
        var draft = ReceiptDraft.empty(pages: input.pages, currency: input.defaultCurrency, date: input.captureDate)
        draft.regions = input.regions
        return proposal.applied(to: draft)
    }

    @Test("Deterministic, Claude, and hybrid strategies are scored on every fictional receipt")
    func evaluate() throws {
        let file = try #require(load(Eval.CaseFile.self, "cases.json"), "Run build_cases.py and make-eval-receipts.swift first")
        #expect(file.cases.count >= 20)
        let summary = load(Eval.ClaudeSummary.self, "results/claude/summary.json")
        var deterministic = Totals(), claude = Totals(), hybrid = Totals()
        var perCase: [String] = []
        var structuringMs: [Double] = [], ocrMs: [Int] = []
        for receipt in file.cases {
            let ocr = try #require(load(Eval.OCRFile.self, "cases/\(receipt.id).ocr.json"), "missing OCR for \(receipt.id)")
            ocrMs.append(ocr.ocrMilliseconds.reduce(0, +))
            let stable = receipt.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            let input = input(ocr, currency: CurrencyCode(receipt.currency), seed: DerivedID.make(ReceiptFixtures.seed, stable))
            let clock = ContinuousClock()
            let start = clock.now
            let local = draft(DeterministicReceiptStructurer.propose(input), input: input)
            let elapsed = (clock.now - start).components
            structuringMs.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            let localScore = score(local, truth: receipt.truth, expectReconciled: receipt.expectReconciled)
            deterministic.add(localScore)

            var cloudDraft: ReceiptDraft?
            if let response = load(ReceiptIntelligenceDTO.Response.self, "results/claude/\(receipt.id).json"),
               let proposal = try? ReceiptIntelligenceMapper.proposal(from: response, input: input) {
                cloudDraft = draft(proposal, input: input)
            }
            if summary != nil {
                claude.add(score(cloudDraft, truth: receipt.truth, expectReconciled: receipt.expectReconciled))
                // Hybrid = what the app shows: Claude's validated proposal, or the on-device draft on any failure.
                let hybridScore = score(cloudDraft ?? local, truth: receipt.truth, expectReconciled: receipt.expectReconciled)
                hybrid.add(hybridScore)
                if cloudDraft == nil { hybrid.fallbacks += 1 }
                let cloudScore = score(cloudDraft, truth: receipt.truth, expectReconciled: receipt.expectReconciled)
                perCase.append("| \(receipt.id) | \(localScore.corrections) | \(cloudDraft == nil ? "failed" : "\(cloudScore.corrections)") "
                    + "| \(hybridScore.corrections) | \(hybridScore.silentErrors) |")
            } else {
                perCase.append("| \(receipt.id) | \(localScore.corrections) | – | – | \(localScore.silentErrors) |")
            }
        }

        var report = ["# Receipt evaluation (fictional set, \(file.cases.count) receipts)", ""]
        report.append("| Strategy | Receipts | Merchant | Date | Currency | Item names | Item amounts | Charge types | Total | Reconciled as expected "
            + "| Fields to correct | Silent errors | Failures | Fallbacks |")
        report.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        report.append(deterministic.row("Deterministic (on device)"))
        if let summary {
            report.append(claude.row("Claude proposal (\(summary.model))"))
            report.append(hybrid.row("Hybrid (validated, with fallback)"))
        }
        let sortedStructuring = structuringMs.sorted(), sortedOCR = ocrMs.sorted()
        report += ["", "Deterministic structuring: median \(String(format: "%.1f", sortedStructuring[sortedStructuring.count / 2])) ms, "
            + "p95 \(String(format: "%.1f", sortedStructuring[Int(Double(sortedStructuring.count - 1) * 0.95)])) ms (simulator). "
            + "Vision OCR (Mac, excluding first-run model load): median \(sortedOCR[sortedOCR.count / 2]) ms."]
        if let summary {
            let latencies = summary.runs.filter { $0.outcome == "ok" }.map(\.latencyMs).sorted()
            let input = summary.runs.map(\.inputTokens).reduce(0, +), output = summary.runs.map(\.outputTokens).reduce(0, +)
            let cost = (Double(input) * summary.inputPricePerMTok + Double(output) * summary.outputPricePerMTok) / 1_000_000 / Double(max(1, summary.runs.count))
            if !latencies.isEmpty {
                report.append("Claude round trip: median \(Int(latencies[latencies.count / 2])) ms, p95 \(Int(latencies[Int(Double(latencies.count - 1) * 0.95)])) ms.")
            }
            report.append("Average usage per receipt: \(input / max(1, summary.runs.count)) input + \(output / max(1, summary.runs.count)) output tokens, "
                + "≈ $\(String(format: "%.4f", cost)) at $\(summary.inputPricePerMTok)/$\(summary.outputPricePerMTok) per MTok.")
        } else {
            report.append("No live Claude results found (results/claude/summary.json). Run server/scripts/run_receipt_eval.py with a key.")
        }
        report += ["", "| Receipt | Deterministic fields to correct | Claude | Hybrid | Hybrid silent errors |", "|---|---:|---:|---:|---:|"] + perCase
        let text = report.joined(separator: "\n") + "\n"
        Attachment.record(text, named: "receipt-eval.md")
        let results = Eval.directory.appending(path: "results")
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try? text.write(to: results.appending(path: "report.md"), atomically: true, encoding: .utf8)

        // Regression floor for the on-device parser at its measured October 2026 baseline (it must keep
        // working offline). Known limitations on this set: amounts with a trailing "€" and Vision
        // reading the rendered "¥" as "·" leave the euro and yen receipts empty on device.
        #expect(deterministic.failures <= 2)
        #expect(deterministic.total * 100 >= deterministic.cases * 85, "the deterministic parser finds most printed totals")
    }
}
