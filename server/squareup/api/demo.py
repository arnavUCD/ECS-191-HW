"""``/v1/demo`` — demo workspaces ("Enter Demo"): start one for this device, reset it, leave it."""

from __future__ import annotations

from flask import Blueprint, Response, jsonify

from .common import principal, services

blueprint = Blueprint("demo", __name__, url_prefix="/v1/demo")


@blueprint.post("/sessions")
def start() -> tuple[Response, int]:
    # Deliberately unlimited (a class may enter the demo from one network at once); the demo can be
    # turned off with SQUAREUP_DEMO_ENABLED=0.
    return jsonify({"session": services().demo.start()}), 201


@blueprint.post("/reset")
def reset() -> Response:
    return jsonify(services().demo.reset(principal()))


@blueprint.delete("/session")
def end() -> Response:
    services().demo.end(principal())
    return jsonify({"ended": True})
