"""Liveness and readiness."""

from __future__ import annotations

from flask import Blueprint, Response, jsonify

from .common import services

blueprint = Blueprint("health", __name__)


@blueprint.get("/healthz")
def healthz() -> Response:
    return jsonify({"status": "ok"})


@blueprint.get("/readyz")
def readyz() -> tuple[Response, int]:
    ready = services().ctx.store.ping()
    return jsonify({"status": "ready" if ready else "unavailable"}), 200 if ready else 503
