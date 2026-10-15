"""``/v1/receipt-room-invitations/{token}`` — validate (preview) and join by link.

``/v1/receipt-room-codes`` — the same by short code. The code travels in the JSON body, never in
the URL path, so it can't reach a request log (no logging exclusion is needed for these routes).
"""

from __future__ import annotations

from flask import Blueprint, Response, jsonify, request

from .common import json_body, limit, principal, services

blueprint = Blueprint("invitations", __name__, url_prefix="/v1/receipt-room-invitations")
codes = Blueprint("room_codes", __name__, url_prefix="/v1/receipt-room-codes")


@blueprint.get("/<token>")
def preview(token: str) -> Response:
    limit("preview")
    return jsonify({"invitation": services().invitations.preview(token, principal())})


@blueprint.post("/<token>/join")
def join(token: str) -> tuple[Response, int]:
    limit("join")
    body = request.get_json(silent=True) or {}
    result = services().invitations.join(token, principal(), body)
    return jsonify(result), 200 if result["restored"] else 201


@codes.post("/preview")
def preview_code() -> Response:
    limit("code")
    return jsonify({"invitation": services().invitations.preview_code(json_body(), principal())})


@codes.post("/join")
def join_code() -> tuple[Response, int]:
    limit("code")
    limit("join")
    result = services().invitations.join_code(principal(), json_body())
    return jsonify(result), 200 if result["restored"] else 201
