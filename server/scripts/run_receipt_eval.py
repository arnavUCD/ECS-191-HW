"""Opt-in live evaluation against Claude with the FICTIONAL receipt set (milestone 5 §12).

Paid API calls. Never part of the automated suite. Requires ANTHROPIC_API_KEY in the environment
(or the gitignored server/.env); the key is never printed.

    cd server
    .venv/bin/python scripts/run_receipt_eval.py                 # every case, one run each
    .venv/bin/python scripts/run_receipt_eval.py --runs 3        # latency distribution
    .venv/bin/python scripts/run_receipt_eval.py --case prompt-injection

Each request goes through the real server stack (validation, prompt, schema, deterministic checks)
with a fresh in-memory store per run, so repeated runs are real provider calls, not cache hits.
Responses are written to Shared/receipt-eval/results/claude/ (gitignored; fictional content only),
with summary.json holding latency and token usage. Then run the Swift evaluation test
(ReceiptEvaluationTests) to score deterministic, Claude, and hybrid results.

`--oracle` exercises the same plumbing without a key: a stand-in provider answers with the ground
truth. Its results are labelled "oracle" and written elsewhere; they say nothing about Claude.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
from decimal import Decimal
from pathlib import Path
from typing import Any

SERVER = Path(__file__).resolve().parents[1]
EVAL = SERVER.parent / "Shared" / "receipt-eval"
sys.path.insert(0, str(SERVER))

from main import load_local_env  # noqa: E402
from squareup import create_app  # noqa: E402
from squareup.config import Config  # noqa: E402
from squareup.intelligence.prompt import PromptPackage  # noqa: E402
from squareup.intelligence.provider import ProviderResult, ReceiptIntelligenceProvider  # noqa: E402
from squareup.intelligence.settings import IntelligenceSettings, key_looks_valid, load_api_key  # noqa: E402

#: Claude Opus 5.5 list prices (USD per million tokens) as published on 2026-09-25. Verify at
#: https://platform.claude.com/docs/en/about-claude/pricing before quoting costs; override with flags.
DEFAULT_INPUT_PRICE = 4.00
DEFAULT_OUTPUT_PRICE = 20.00


def request_body(case_id: str, currency: str) -> dict[str, Any]:
    ocr = json.loads((EVAL / "cases" / f"{case_id}.ocr.json").read_text())
    pages = [
        {"index": index, "image": base64.b64encode((EVAL / "cases" / name).read_bytes()).decode(), "warnings": []}
        for index, name in enumerate(ocr["pages"])
    ]
    return {
        "schemaVersion": 1,
        "consent": {"mode": "automatic", "version": 1},
        "locale": "en_US",
        "likelyCurrency": currency,
        "pages": pages,
        "regions": ocr["regions"],
    }


class OracleProvider:
    """Answers with the ground truth (plumbing check only). Cites the regions whose text holds each value."""

    name = "oracle"
    model = "oracle"

    def __init__(self, case: dict[str, Any]) -> None:
        self.case = case

    @property
    def available(self) -> bool:
        return True

    def complete(self, package: PromptPackage, deadline: float) -> ProviderResult:
        document = json.loads(package.content[-2]["text"].split("\n")[1].replace("\\u003c", "<").replace("\\u003e", ">"))
        ocr = document["ocr"]

        def refs(text: str) -> list[str]:
            needle = text.replace(".", "").replace(",", "")
            return [row[0] for row in ocr if needle and needle in row[4].replace(".", "").replace(",", "")][:2]

        def field(value: str | None, *, basis: str = "visible") -> dict[str, Any]:
            return {
                "value": value,
                "confidence": "high",
                "basis": basis if value else "absent",
                "regionIds": refs(value or ""),
                "uncertainty": "none",
            }

        truth = self.case["truth"]
        output = {
            "merchant": field(truth["merchant"]),
            "date": field(truth["date"], basis="layout"),
            "currency": field(truth["currency"], basis="layout"),
            "items": [
                {
                    "name": field(i["name"]),
                    "quantity": field(None),
                    "unitPrice": field(None),
                    "lineTotal": field(i["amount"]),
                    "isRefund": Decimal(i["amount"]) < 0,
                }
                for i in truth["items"]
            ],
            "charges": [{"kind": c["kind"], "label": c["kind"], "amount": field(c["amount"])} for c in truth["charges"]],
            "subtotal": field(truth["subtotal"]),
            "total": field(truth["total"]),
            "warnings": [],
            "overallConfidence": "high",
        }
        return ProviderResult(json.dumps(output), "oracle")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--case", action="append", help="Only these case IDs (repeatable)")
    parser.add_argument("--runs", type=int, default=1, help="Runs per case (latency distribution)")
    parser.add_argument("--input-price", type=float, default=DEFAULT_INPUT_PRICE, help="USD per million input tokens")
    parser.add_argument("--output-price", type=float, default=DEFAULT_OUTPUT_PRICE, help="USD per million output tokens")
    parser.add_argument("--oracle", action="store_true", help="No API calls: answer with the ground truth (plumbing check)")
    parser.add_argument("--output", type=Path, help="Results directory (default Shared/receipt-eval/results/claude)")
    args = parser.parse_args(argv)

    load_local_env(SERVER / ".env")
    key = load_api_key()
    if not args.oracle and (key is None or not key_looks_valid(key)):
        print("ANTHROPIC_API_KEY is not set or doesn't look like an Anthropic key. Set it in your shell or in the gitignored")
        print("server/.env (see server/README.md). Nothing was sent.")
        return 2
    output = args.output or EVAL / "results" / ("oracle" if args.oracle else "claude")
    output.mkdir(parents=True, exist_ok=True)
    cases = json.loads((EVAL / "cases.json").read_text())["cases"]
    if args.case:
        cases = [c for c in cases if c["id"] in set(args.case)]
    settings = IntelligenceSettings.from_environment({**os.environ, "SQUAREUP_AI_PROVIDER": "anthropic"})
    limits = dict.fromkeys(("intelligence", "intelligence-daily", "intelligence-global", "command"), (10_000, 60))
    runs: list[dict[str, Any]] = []
    model = "oracle" if args.oracle else settings.model
    for case in cases:
        body = request_body(case["id"], case["currency"])
        for attempt in range(args.runs):
            provider: ReceiptIntelligenceProvider
            if args.oracle:
                provider = OracleProvider(case)
            else:
                from squareup.intelligence.anthropic_provider import ClaudeReceiptProvider

                assert key is not None  # noqa: S101 - checked above
                provider = ClaudeReceiptProvider(key, settings)
            app = create_app(
                Config(environment="development", allow_dev_auth=True, intelligence=settings, rate_limits=limits),
                intelligence_provider=provider,
            )
            started = time.monotonic()
            response = app.test_client().post("/v1/receipt-intelligence/parse", json=body, headers={"Authorization": "Dev eval-runner"})
            latency = (time.monotonic() - started) * 1000
            tokens = app.extensions["squareup"].intelligence.metrics.snapshot()["tokens"]
            data = response.get_json(silent=True) or {}
            outcome = "ok" if response.status_code == 200 else data.get("error", {}).get("code", str(response.status_code))
            if response.status_code == 200:
                model = data.get("model", model)
            if attempt == 0:
                (output / f"{case['id']}.json").write_text(
                    json.dumps(data if response.status_code == 200 else {"error": data.get("error")}, indent=1)
                )
            runs.append(
                {
                    "id": case["id"],
                    "outcome": outcome,
                    "latencyMs": round(latency, 1),
                    "inputTokens": tokens["input"],
                    "outputTokens": tokens["output"],
                }
            )
            print(
                f"{case['id']:<28} run {attempt + 1}: {outcome:<20} {latency:8.0f} ms  {tokens['input']:>6} in / {tokens['output']:>5} out"
            )
    summary = {"model": model, "inputPricePerMTok": args.input_price, "outputPricePerMTok": args.output_price, "runs": runs}
    (output / "summary.json").write_text(json.dumps(summary, indent=1))
    ok = [r for r in runs if r["outcome"] == "ok"]
    total_in, total_out = sum(r["inputTokens"] for r in runs), sum(r["outputTokens"] for r in runs)
    cost = (total_in * args.input_price + total_out * args.output_price) / 1_000_000
    print(
        f"\n{len(ok)}/{len(runs)} succeeded. Tokens: {total_in} in, {total_out} out. Approximate cost: ${cost:.4f} "
        f"(${cost / max(1, len(runs)):.4f} per receipt at ${args.input_price}/${args.output_price} per MTok)."
    )
    print(f"Results: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
