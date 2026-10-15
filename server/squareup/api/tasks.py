"""Scheduled maintenance. Only App Engine cron (or development) may call these."""

from __future__ import annotations

from flask import Blueprint, Response, jsonify, request

from ..domain.errors import DomainError
from .common import services

blueprint = Blueprint("tasks", __name__, url_prefix="/tasks")


@blueprint.get("/cleanup")
def cleanup() -> Response:
    config = services().ctx.config
    # App Engine removes X-Appengine-Cron from external requests, so only its scheduler can set it.
    if request.headers.get("X-Appengine-Cron") != "true" and config.is_production:
        raise DomainError("forbidden", "Not allowed")
    if request.headers.get("X-Appengine-Cron") != "true" and not config.allow_dev_auth:
        raise DomainError("forbidden", "Not allowed")
    return jsonify({"removed": services().cleanup.run()})
