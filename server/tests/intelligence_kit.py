"""Fictional receipt fixtures for receipt-intelligence tests (no real merchant, person, or card)."""

from __future__ import annotations

import base64
import copy
import json
import uuid
from typing import Any

ACCOUNT = {"Authorization": "Bearer valid-ai-user"}
OTHER_ACCOUNT = {"Authorization": "Bearer valid-someone-else"}
PARSE = "/v1/receipt-intelligence/parse"

#: Vision-style regions for "Lantern Noodle House" (fictional), in reading order.
REGION_TEXT = [
    "LANTERN NOODLE HOUSE",
    "2026-09-30 19:42",
    "2 x DUMPLINGS 4.50 9.00",
    "SPICY NOODLES 12.50",
    "SUBTOTAL 21.50",
    "TAX 1.94",
    "TOTAL 23.44",
    "VISA ****0000 AUTH 000000",
]


def jpeg(width: int = 900, height: int = 2000, *, exif: bool = True) -> bytes:
    """A structurally valid baseline JPEG header (SOF0 with dimensions), optionally with EXIF/GPS."""
    app0 = b"\xff\xe0" + (16).to_bytes(2, "big") + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    payload = b"Exif\x00\x00GPS:38.5N!"
    meta = b"\xff\xe1" + (len(payload) + 2).to_bytes(2, "big") + payload if exif else b""
    sof = b"\xff\xc0" + (17).to_bytes(2, "big") + b"\x08" + height.to_bytes(2, "big") + width.to_bytes(2, "big")
    sof += b"\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01"
    scan = b"\xff\xda" + (8).to_bytes(2, "big") + b"\x01\x01\x00\x00\x3f\x00" + b"\x12\x34\x56" + b"\xff\xd9"
    return b"\xff\xd8" + app0 + meta + sof + scan


def regions(texts: list[str] | None = None, page: int = 0) -> list[dict[str, Any]]:
    """Client regions with UUID identifiers (the server must map aliases back to these)."""
    lines = REGION_TEXT if texts is None else texts
    return [
        {
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"region-{page}-{index}")),
            "page": page,
            "order": index,
            "text": text,
            "confidence": 0.95,
            "box": [0.1, 0.05 + index * 0.06, 0.8, 0.03],
            "alternatives": [],
        }
        for index, text in enumerate(lines)
    ]


def request_body(*, images: list[bytes] | None = None, texts: list[str] | None = None, **overrides: Any) -> dict[str, Any]:
    pages = images if images is not None else [jpeg()]
    body: dict[str, Any] = {
        "schemaVersion": 1,
        "consent": {"mode": "automatic", "version": 1},
        "locale": "en_US",
        "likelyCurrency": "USD",
        "pages": [{"index": i, "image": base64.b64encode(image).decode(), "warnings": []} for i, image in enumerate(pages)],
        "regions": regions(texts),
    }
    body.update(overrides)
    return body


def field(value: str | None, *refs: str, confidence: str = "high", basis: str = "visible", uncertainty: str = "none") -> dict[str, Any]:
    return {
        "value": value,
        "confidence": confidence,
        "basis": "absent" if value is None else basis,
        "regionIds": list(refs),
        "uncertainty": uncertainty,
    }


def output(**overrides: Any) -> dict[str, Any]:
    """A correct provider output for :data:`REGION_TEXT` (aliases r1…r8)."""
    proposal: dict[str, Any] = {
        "merchant": field("Lantern Noodle House", "r1"),
        "date": field("2026-09-30", "r2"),
        "currency": field("USD", basis="layout", confidence="high"),
        "items": [
            {
                "name": field("Dumplings", "r3"),
                "quantity": field("2", "r3"),
                "unitPrice": field("4.50", "r3"),
                "lineTotal": field("9.00", "r3"),
                "isRefund": False,
            },
            {
                "name": field("Spicy Noodles", "r4"),
                "quantity": field(None),
                "unitPrice": field(None),
                "lineTotal": field("12.50", "r4"),
                "isRefund": False,
            },
        ],
        "charges": [{"kind": "tax", "label": "Tax", "amount": field("1.94", "r6")}],
        "subtotal": field("21.50", "r5"),
        "total": field("23.44", "r7"),
        "warnings": [{"code": "cardDetailsIgnored", "regionIds": ["r8"]}],
        "overallConfidence": "high",
    }
    proposal.update(copy.deepcopy(overrides))
    return proposal


def text(proposal: dict[str, Any]) -> str:
    return json.dumps(proposal)
