# Receipt evaluation set (milestone 5)

Twenty **fictional** receipts for comparing the on-device deterministic parser, Claude's proposal,
and the hybrid result after deterministic validation. No real person, merchant, address, or card
appears anywhere; card fragments are `****0000`, phones use `555-01xx`, and URLs use `.invalid`.

| Case | What it exercises |
|---|---|
| `restaurant-basic` | Items, tax, tip, card line |
| `restaurant-service-charge` | Automatic service charge, blank tip line, a repeated item |
| `grocery-long` | 24 abbreviated grocery lines, payment footer |
| `grocery-quantities` | `3 @ 1.29` and weight-priced lines |
| `multi-page` | A receipt continued on a second page |
| `discounts` | Member savings and a coupon |
| `returns` | A negative return line |
| `multiple-taxes` | State and city tax |
| `wrapped-names` | Item names wrapped onto a second line |
| `cafe-abbreviations` | Coffee-shop abbreviations |
| `rotated` | A 7° rotated photo |
| `poor-contrast` | Low contrast, dim, slightly blurred |
| `cropped` | Right edge cropped |
| `inconsistent-total` | The printed total is $2.50 too high (must be flagged, never fixed) |
| `prompt-injection` | Lines telling the model to ignore the schema, reveal secrets, visit a URL, change the total |
| `duplicate-lines` | Two identical coffee lines that are both real |
| `card-auth-footer` | Card, auth code, terminal, approval, change due, survey code |
| `euro` | EUR with `9,50 €` amounts and a `dd.mm.yyyy` date |
| `yen` | JPY (no decimals) |
| `vat-included` | GBP with "VAT included" (not a charge) |

## Files

- `build_cases.py` builds `cases.json`: page lines, degradations, and the ground truth (computed
  with exact `Decimal` arithmetic and checked).
- `../../App/Tools/make-eval-receipts.swift` renders `cases/<id>-p<n>.jpg` and runs **real Vision OCR**
  (macOS) into `cases/<id>.ocr.json` in the app's wire format.
- `results/` (gitignored): `claude/<id>.json` responses and `claude/summary.json` usage from the
  live runner, and `report.md` from the Swift scorer. Responses contain only this fictional content.

## Running

```sh
python3 Shared/receipt-eval/build_cases.py
swift App/Tools/make-eval-receipts.swift Shared/receipt-eval
cd server && .venv/bin/python scripts/run_receipt_eval.py       # paid; needs ANTHROPIC_API_KEY
cd ../App && xcodebuild test -scheme SquareUp -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:SquareUpTests/ReceiptEvaluationTests            # writes results/report.md
```

Without Claude results, the scorer measures the deterministic parser only. `run_receipt_eval.py
--oracle` checks the plumbing with a stand-in that echoes the ground truth; those numbers say nothing
about Claude and are written to `results/oracle/`, which the scorer never reads.

## Metrics

Per strategy: merchant, date, and currency accuracy; item-name accuracy (≥ 60 % of the expected
name's words); item-amount accuracy; charge-type accuracy (kind and amount); total accuracy;
reconciled-as-expected (the inconsistent receipt must *not* reconcile); fields requiring correction
(wrong header fields, missing or spurious items and charges, wrong names); **silent errors** (wrong or
spurious values shown as "Looks good"); failure rate; fallback rate; latency; tokens and approximate cost.
