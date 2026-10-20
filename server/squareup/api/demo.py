"""``/v1/demo`` — demo workspaces ("Enter Demo"): start one for this device, reset it, leave it."""

from __future__ import annotations

from flask import Blueprint, Response, jsonify

from .common import limit, network_key, principal, services

blueprint = Blueprint("demo", __name__, url_prefix="/v1/demo")


@blueprint.post("/sessions")
def start() -> tuple[Response, int]:
    # Each start creates a workspace of sample records, so it's limited per network (generously: a
    # class on one Wi-Fi shares an address) and per day for everyone (the cost ceiling). Both are
    # configurable (SQUAREUP_DEMO_STARTS_PER_NETWORK_PER_HOUR, SQUAREUP_DEMO_STARTS_PER_DAY), and
    # SQUAREUP_DEMO_ENABLED=0 turns the demo off. Counted in the store, so it holds across instances.
    limit("demo-start", client=network_key(), message="Too many demos were started from this network. Try again later")
    limit("demo-start-daily", client="all", message="The demo is busy right now. Try again later")
    return jsonify({"session": services().demo.start()}), 201


@blueprint.post("/reset")
def reset() -> Response:
    return jsonify(services().demo.reset(principal()))


@blueprint.delete("/session")
def end() -> Response:
    services().demo.end(principal())
    return jsonify({"ended": True})
