"""Receipt image bytes. Objects are private: clients never receive a Cloud Storage URL; the server
streams bytes after checking the room credential (an authenticated server route)."""

from __future__ import annotations

import threading
from abc import ABC, abstractmethod


class BlobStore(ABC):
    @abstractmethod
    def put(self, name: str, data: bytes, content_type: str) -> None: ...

    @abstractmethod
    def get(self, name: str) -> bytes | None: ...

    @abstractmethod
    def delete(self, name: str) -> None: ...


class MemoryBlobStore(BlobStore):
    def __init__(self) -> None:
        self._objects: dict[str, bytes] = {}
        self._lock = threading.Lock()

    def put(self, name: str, data: bytes, content_type: str) -> None:
        with self._lock:
            self._objects[name] = data

    def get(self, name: str) -> bytes | None:
        with self._lock:
            return self._objects.get(name)

    def delete(self, name: str) -> None:
        with self._lock:
            self._objects.pop(name, None)

    def names(self) -> list[str]:
        with self._lock:
            return sorted(self._objects)


class GCSBlobStore(BlobStore):
    """A private bucket (uniform bucket-level access, no public principals). The App Engine service
    account needs only ``roles/storage.objectAdmin`` on this one bucket."""

    def __init__(self, bucket: str, project: str | None) -> None:
        from google.cloud import storage  # type: ignore[attr-defined]  # namespace package without stubs

        self._bucket = storage.Client(project=project).bucket(bucket)

    def put(self, name: str, data: bytes, content_type: str) -> None:
        blob = self._bucket.blob(name)
        blob.cache_control = "private, max-age=0, no-store"
        blob.upload_from_string(data, content_type=content_type)

    def get(self, name: str) -> bytes | None:
        from google.api_core.exceptions import NotFound

        try:
            data: bytes = self._bucket.blob(name).download_as_bytes()
            return data
        except NotFound:
            return None

    def delete(self, name: str) -> None:
        from google.api_core.exceptions import NotFound

        try:
            self._bucket.blob(name).delete()
        except NotFound:
            return
