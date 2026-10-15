"""``/v1/receipt-intelligence`` — hybrid receipt parsing (milestone 5). Accounts only."""

from __future__ import annotations

import json

from flask import Blueprint, Response, jsonify, request

from ..domain.errors import DomainError
from .common import limit, principal, services

blueprint = Blueprint("receipt_intelligence", __name__, url_prefix="/v1/receipt-intelligence")


@blueprint.post("/parse")
def parse() -> Response:
    svc = services()
    caller = svc.intelligence.require_account(principal())
    if not caller.demo:
        limit("intelligence")
    maximum = svc.ctx.config.intelligence.max_request_bytes
    if (request.content_length or 0) > maximum:
        raise DomainError("payload_too_large", "That receipt is too large to process")
    data = request.get_data(cache=False)
    if len(data) > maximum:
        raise DomainError("payload_too_large", "That receipt is too large to process")
    try:
        body = json.loads(data)
    except (ValueError, RecursionError) as error:
        raise DomainError("invalid_payload", "Expected a JSON body") from error
    return jsonify(svc.intelligence.parse(caller, body))


@blueprint.delete("/cache")
def delete_cache() -> Response:
    limit("command")
    return jsonify({"removed": services().intelligence.delete_cache(principal())})
