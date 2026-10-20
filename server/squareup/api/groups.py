"""``/v1/account`` and ``/v1/groups`` — profiles, destinations, shared groups, sync, invitations (milestone 7),
and direct invitations ("Find a person")."""

from __future__ import annotations

from flask import Blueprint, Response, jsonify, request

from ..domain.errors import DomainError
from ..domain.room import require_int
from .common import json_body, limit, principal, services

accounts = Blueprint("accounts", __name__, url_prefix="/v1/account")
groups = Blueprint("groups", __name__, url_prefix="/v1/groups")
group_invitations = Blueprint("group_invitations", __name__, url_prefix="/v1/group-invitations")


# MARK: - Account and profile


@accounts.get("")
def get_account() -> Response:
    limit("account")
    return jsonify({"account": services().accounts.account(principal())})


@accounts.get("/deletion")
def account_deletion_check() -> Response:
    """What deleting the account would do now, and what has to happen first."""
    limit("account")
    return jsonify({"deletion": services().account_deletion.check(principal())})


@accounts.delete("")
def delete_account() -> Response:
    """Deletes the account's Square Up data (services.account_deletion); needs a recent sign-in."""
    limit("account-delete")
    return jsonify(services().account_deletion.delete(principal()))


@accounts.put("/profile")
def save_profile() -> Response:
    limit("account")
    return jsonify({"profile": services().accounts.save_profile(principal(), json_body())})


@accounts.put("/destinations/<destination_id>")
def save_destination(destination_id: str) -> Response:
    limit("account")
    return jsonify({"profile": services().accounts.save_destination(principal(), destination_id, json_body())})


@accounts.delete("/destinations/<destination_id>")
def delete_destination(destination_id: str) -> Response:
    limit("account")
    return jsonify({"profile": services().accounts.delete_destination(principal(), destination_id)})


# MARK: - Invitations sent to this account ("Find a person")


@accounts.get("/invitations")
def received_invitations() -> Response:
    limit("group-read")
    return jsonify({"invitations": services().direct_invitations.received(principal())})


@accounts.post("/invitations/<invitation_id>/accept")
def accept_direct_invitation(invitation_id: str) -> tuple[Response, int]:
    limit("group-invite-accept")
    body = request.get_json(silent=True) or {}
    snapshot, joined = services().direct_invitations.accept(principal(), invitation_id, body)
    return jsonify({"snapshot": snapshot, "joined": joined}), 201 if joined else 200


@accounts.post("/invitations/<invitation_id>/decline")
def decline_direct_invitation(invitation_id: str) -> Response:
    limit("group-invite-accept")
    return jsonify({"invitation": services().direct_invitations.decline(principal(), invitation_id)})


# MARK: - Groups


@groups.get("")
def list_groups() -> Response:
    limit("group-read")
    return jsonify({"groups": services().groups.list_groups(principal())})


@groups.post("")
def create_group() -> tuple[Response, int]:
    limit("group-publish")
    snapshot, created = services().groups.create(principal(), json_body())
    return jsonify({"snapshot": snapshot, "created": created}), 201 if created else 200


@groups.post("/publications")
def publish_group() -> tuple[Response, int]:
    limit("group-publish")
    snapshot, created = services().groups.publish(principal(), json_body())
    return jsonify({"snapshot": snapshot, "created": created}), 201 if created else 200


@groups.get("/<group_id>")
def get_group(group_id: str) -> Response:
    limit("group-read")
    return jsonify({"snapshot": services().groups.snapshot(principal(), group_id)})


@groups.get("/<group_id>/changes")
def get_changes(group_id: str) -> Response:
    limit("group-read")
    raw = request.args.get("after", "")
    if not raw.isdigit() or len(raw) > 9:
        raise DomainError("cursor_invalid", "after must be an event cursor")
    after = require_int(int(raw), "after", low=0, high=100_000_000)
    return jsonify({"changes": services().groups.changes(principal(), group_id, after)})


@groups.post("/<group_id>/commands")
def command(group_id: str) -> Response:
    limit("group-command")
    return jsonify(services().groups.command(principal(), group_id, json_body()))


@groups.get("/<group_id>/members/<member_id>/destinations")
def reveal_destinations(group_id: str, member_id: str) -> Response:
    limit("reveal")
    response = jsonify(services().groups.reveal_destinations(principal(), group_id, member_id))
    response.headers["Cache-Control"] = "private, no-store"
    return response


@groups.get("/<group_id>/receipts/<receipt_id>")
def get_receipt(group_id: str, receipt_id: str) -> Response:
    limit("group-read")
    return jsonify({"receipt": services().groups.receipt(principal(), group_id, receipt_id)})


@groups.get("/<group_id>/expenses/<expense_id>/revisions")
def revisions(group_id: str, expense_id: str) -> Response:
    limit("group-read")
    return jsonify({"revisions": services().groups.revisions(principal(), group_id, expense_id)})


@groups.post("/<group_id>/invitations")
def create_invitation(group_id: str) -> tuple[Response, int]:
    limit("group-invite")
    body = request.get_json(silent=True) or {}
    return jsonify({"invitation": services().groups.create_invitation(principal(), group_id, body)}), 201


@groups.get("/<group_id>/invitations")
def list_invitations(group_id: str) -> Response:
    limit("group-read")
    return jsonify({"invitations": services().groups.list_invitations(principal(), group_id)})


@groups.delete("/<group_id>/invitations/<invitation_id>")
def revoke_invitation(group_id: str, invitation_id: str) -> Response:
    limit("group-invite")
    return jsonify({"invitation": services().groups.revoke_invitation(principal(), group_id, invitation_id)})


# MARK: - Finding a person (any member)


def _limit_lookup() -> None:
    limit("group-lookup")
    limit("group-lookup-daily")


@groups.post("/<group_id>/people/lookup")
def lookup_person(group_id: str) -> Response:
    # The email or phone number is in the body, never the URL, so it can't reach a request log.
    _limit_lookup()
    return jsonify(services().direct_invitations.lookup(principal(), group_id, json_body()))


@groups.post("/<group_id>/direct-invitations")
def create_direct_invitation(group_id: str) -> tuple[Response, int]:
    limit("group-invite")
    _limit_lookup()  # inviting looks the person up again
    return jsonify({"invitation": services().direct_invitations.invite(principal(), group_id, json_body())}), 201


@groups.get("/<group_id>/direct-invitations")
def list_direct_invitations(group_id: str) -> Response:
    limit("group-read")
    return jsonify({"invitations": services().direct_invitations.sent(principal(), group_id)})


@groups.delete("/<group_id>/direct-invitations/<invitation_id>")
def cancel_direct_invitation(group_id: str, invitation_id: str) -> Response:
    limit("group-invite")
    return jsonify({"invitation": services().direct_invitations.cancel(principal(), group_id, invitation_id)})


# MARK: - Invitation holders


@group_invitations.get("/<code>")
def preview(code: str) -> Response:
    limit("group-invite-preview")
    return jsonify({"invitation": services().groups.preview_invitation(code, principal())})


@group_invitations.post("/<code>/accept")
def accept(code: str) -> tuple[Response, int]:
    limit("group-invite-accept")
    body = request.get_json(silent=True) or {}
    snapshot, joined = services().groups.accept_invitation(code, principal(), body)
    return jsonify({"snapshot": snapshot, "joined": joined}), 201 if joined else 200
