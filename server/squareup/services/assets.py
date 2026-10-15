"""Shared receipt images (milestone 4 §10).

Only the host uploads, only room participants download, and only through this authenticated
route — objects are never public. Uploads must be baseline or progressive JPEG; every metadata
segment except the JFIF header (EXIF, GPS, XMP, ICC, comments) is removed before storage.
"""

from __future__ import annotations

from datetime import timedelta

from ..auth.identity import Principal
from ..domain.errors import DomainError
from ..domain.room import HistoryEntry, new_id, require_uuid
from ..domain.wire import room_from_storage
from ..logging_setup import log_event, redact
from ..storage.base import ASSET, ROOM, Transaction
from .context import ServiceContext, iso
from .rooms import RoomService

MAX_ASSETS_PER_ROOM = 6
_KEEP_MARKERS = {0xE0}  # APP0 (JFIF); drop APP1–APP15 and COM


def strip_jpeg_metadata(data: bytes) -> bytes:
    """Remove APPn (n ≥ 1) and COM segments. Raises ``unsupported_media`` for anything else."""
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        raise DomainError("unsupported_media", "Receipt images must be JPEG")
    output = bytearray(b"\xff\xd8")
    index = 2
    while index < len(data):
        if data[index] != 0xFF:
            raise DomainError("unsupported_media", "The image is damaged")
        marker = data[index + 1] if index + 1 < len(data) else 0
        if marker == 0xD9:
            output += data[index : index + 2]
            return bytes(output)
        if marker == 0xDA:  # start of scan: the rest is entropy-coded data
            output += data[index:]
            return bytes(output)
        if index + 4 > len(data):
            raise DomainError("unsupported_media", "The image is damaged")
        length = int.from_bytes(data[index + 2 : index + 4], "big")
        segment = data[index : index + 2 + length]
        if len(segment) != 2 + length or length < 2:
            raise DomainError("unsupported_media", "The image is damaged")
        is_metadata = (0xE1 <= marker <= 0xEF) or marker == 0xFE
        if not is_metadata or marker in _KEEP_MARKERS:
            output += segment
        index += 2 + length
    raise DomainError("unsupported_media", "The image is damaged")


class AssetService:
    def __init__(self, ctx: ServiceContext, rooms: RoomService) -> None:
        self.ctx = ctx
        self.rooms = rooms

    def upload(self, principal: Principal | None, room_id: str, data: bytes, content_type: str | None) -> dict[str, object]:
        room = self.rooms.load(room_id)
        actor = self.rooms.actor_for(room, principal)
        if not actor.is_host:
            raise DomainError("host_only", "Only the host can share the receipt image")
        if room.state in ("finalized", "cancelled"):
            raise DomainError("room_finalized" if room.state == "finalized" else "room_cancelled", "This room is closed")
        if content_type not in ("image/jpeg", "image/jpg"):
            raise DomainError("unsupported_media", "Receipt images must be JPEG")
        if len(data) > self.ctx.config.max_asset_bytes:
            raise DomainError("payload_too_large", "That image is too large")
        if len(room.asset_ids) >= MAX_ASSETS_PER_ROOM:
            raise DomainError("invalid_payload", "This room already has the maximum number of images")
        clean = strip_jpeg_metadata(data)
        asset_id = new_id()
        object_name = f"rooms/{room.id}/{asset_id}.jpg"
        self.ctx.blobs.put(object_name, clean, "image/jpeg")
        now = self.ctx.now_iso()

        def body(transaction: Transaction) -> int:
            record = transaction.get(ROOM, room.id)
            if record is None:
                raise DomainError("room_not_found", "This receipt isn't available")
            fresh = room_from_storage(record)
            fresh.asset_ids.append(asset_id)
            fresh.revision += 1
            fresh.updated_at = now
            fresh.history.append(
                HistoryEntry(
                    fresh.history[-1].sequence + 1 if fresh.history else 1, fresh.revision, actor.participant_id, now, "assetAdded", {}
                )
            )
            self.rooms._put_room(transaction, fresh)
            transaction.put(
                ASSET,
                asset_id,
                {"roomId": room.id, "objectName": object_name, "bytes": len(clean), "createdAt": now},
                indexed={"roomId": room.id},
            )
            return fresh.revision

        try:
            revision = self.ctx.store.run_in_transaction(body)
        except Exception:
            self.ctx.blobs.delete(object_name)
            raise
        log_event("asset.uploaded", room=redact(room.id), bytes=len(clean))
        return {"assetId": asset_id, "revision": revision}

    def download(self, principal: Principal | None, room_id: str, asset_id: str) -> bytes:
        room = self.rooms.load(room_id)
        self.rooms.actor_for(room, principal)
        asset_id = require_uuid(asset_id, "assetId")
        record = self.ctx.store.get(ASSET, asset_id)
        if record is None or record["roomId"] != room.id or asset_id not in room.asset_ids:
            raise DomainError("asset_not_found", "That image isn't available")
        data = self.ctx.blobs.get(record["objectName"])
        if data is None:
            raise DomainError("asset_not_found", "That image isn't available")
        return data

    def expire(self) -> int:
        """Delete images of rooms finished longer than the retention period ago."""
        cutoff = iso(self.ctx.now() - timedelta(days=self.ctx.config.asset_retention_days))
        removed = 0
        for room_id, record in self.ctx.store.query_before(ROOM, "finishedAt", cutoff):
            for asset_id in record.get("assetIds", []):
                asset = self.ctx.store.get(ASSET, asset_id)
                if asset is not None:
                    self.ctx.blobs.delete(asset["objectName"])
                removed += 1

            def body(transaction: Transaction, room_id: str = room_id) -> None:
                current = transaction.get(ROOM, room_id)
                if current is None:
                    return
                for asset_id in current.get("assetIds", []):
                    transaction.delete(ASSET, asset_id)
                current["assetIds"] = []
                transaction.put(
                    ROOM,
                    room_id,
                    current,
                    indexed={
                        "hostUid": current["hostUid"],
                        "state": current["state"],
                        "updatedAt": current["updatedAt"],
                        "finishedAt": None,
                    },
                )

            self.ctx.store.run_in_transaction(body)
        return removed
