"""``/v1/receipt-rooms`` — publish, read, command, finalize, invitations, assets, guest linking."""

from __future__ import annotations

from flask import Blueprint, Response, jsonify, request

from ..domain.errors import DomainError
from .common import json_body, limit, principal, services

blueprint = Blueprint("receipt_rooms", __name__, url_prefix="/v1/receipt-rooms")


@blueprint.post("")
def publish() -> tuple[Response, int]:
    limit("publish")
    snapshot, created = services().rooms.publish(principal(), json_body())
    return jsonify({"room": snapshot, "created": created}), 201 if created else 200


@blueprint.get("/<room_id>")
def get_room(room_id: str) -> Response:
    limit("command")
    return jsonify({"room": services().rooms.snapshot(principal(), room_id)})


@blueprint.get("/<room_id>/history")
def history(room_id: str) -> Response:
    limit("command")
    return jsonify({"history": services().rooms.history(principal(), room_id)})


def _command(room_id: str, forced_type: str | None) -> Response:
    limit("command")
    caller = principal()
    try:
        return jsonify(services().rooms.command(caller, room_id, json_body(), forced_type))
    except DomainError as error:
        if error.code in _WITH_SNAPSHOT:
            snapshot = services().rooms.conflict_snapshot(caller, room_id)
            if snapshot is not None:
                error.details["room"] = snapshot
        raise


#: Refusals that come back with the room as it is now, so the person sees what changed.
_WITH_SNAPSHOT = frozenset(
    {
        "revision_conflict",
        "room_finalized",
        "room_cancelled",
        "not_ready_to_finalize",
        "unresolved_dispute",
        "unreviewed_shares",
        "item_already_claimed",
        "units_unavailable",
        "room_expired",
        "room_closed",
    }
)


@blueprint.get("/<room_id>/payment-destinations")
def payment_destinations(room_id: str) -> Response:
    limit("reveal")
    response = jsonify(services().rooms.payment_destinations(principal(), room_id))
    response.headers["Cache-Control"] = "private, no-store"
    return response


@blueprint.post("/<room_id>/commands")
def command(room_id: str) -> Response:
    return _command(room_id, None)


@blueprint.post("/<room_id>/finalize")
def finalize(room_id: str) -> Response:
    return _command(room_id, "finalize")


@blueprint.post("/<room_id>/invitations")
def create_invitation(room_id: str) -> tuple[Response, int]:
    limit("publish")
    body = request.get_json(silent=True) or {}
    return jsonify({"invitation": services().invitations.create(principal(), room_id, body)}), 201


@blueprint.get("/<room_id>/invitations")
def list_invitations(room_id: str) -> Response:
    limit("command")
    return jsonify({"invitations": services().invitations.list(principal(), room_id)})


@blueprint.delete("/<room_id>/invitations/<invitation_id>")
def revoke_invitation(room_id: str, invitation_id: str) -> Response:
    limit("command")
    return jsonify({"invitation": services().invitations.revoke(principal(), room_id, invitation_id)})


@blueprint.post("/<room_id>/link-guest")
def link_guest(room_id: str) -> Response:
    limit("join")
    return jsonify({"room": services().rooms.link_guest(principal(), room_id, json_body())})


@blueprint.post("/<room_id>/receipt-assets")
def upload_asset(room_id: str) -> tuple[Response, int]:
    limit("asset")
    data = request.get_data(cache=False)
    return jsonify(services().assets.upload(principal(), room_id, data, request.mimetype)), 201


@blueprint.get("/<room_id>/receipt-assets/<asset_id>")
def download_asset(room_id: str, asset_id: str) -> Response:
    limit("asset")
    data = services().assets.download(principal(), room_id, asset_id)
    response = Response(data, mimetype="image/jpeg")
    response.headers["Cache-Control"] = "private, no-store"
    return response
