"""Processing-image checks (milestone 5 §4, §8): JPEG only, sane dimensions, metadata removed.

Uses the same segment-level stripper as shared receipt images (EXIF, GPS, XMP, ICC, comments),
then reads the frame header to enforce dimensions without decoding pixels.
"""

from __future__ import annotations

from ..domain.errors import DomainError
from ..services.assets import strip_jpeg_metadata

MIN_SIDE = 64
MAX_SIDE = 8000
#: Start-of-frame markers that carry dimensions (excludes DHT C4, JPG C8, DAC CC).
_SOF = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def jpeg_dimensions(data: bytes) -> tuple[int, int]:
    """(width, height) from the first frame header. Raises ``unsupported_media``."""
    if data[:2] != b"\xff\xd8":
        raise DomainError("unsupported_media", "Receipt images must be JPEG")
    index = 2
    while index + 4 <= len(data):
        if data[index] != 0xFF:
            break
        marker = data[index + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            index += 2
            continue
        if marker in (0xD9, 0xDA):
            break
        length = int.from_bytes(data[index + 2 : index + 4], "big")
        if length < 2 or index + 2 + length > len(data):
            break
        if marker in _SOF and length >= 7:
            height = int.from_bytes(data[index + 5 : index + 7], "big")
            width = int.from_bytes(data[index + 7 : index + 9], "big")
            return width, height
        index += 2 + length
    raise DomainError("unsupported_media", "The image is damaged")


def prepare_image(data: bytes) -> tuple[bytes, int, int]:
    """Strip metadata and check dimensions. Returns (clean bytes, width, height)."""
    clean = strip_jpeg_metadata(data)
    width, height = jpeg_dimensions(clean)
    if min(width, height) < MIN_SIDE or max(width, height) > MAX_SIDE:
        raise DomainError("unsupported_media", "That image size isn't supported")
    return clean, width, height


def visual_tokens(width: int, height: int) -> int:
    """Claude's documented image cost before any server-side downscaling: ⌈w/28⌉·⌈h/28⌉."""
    return -(-width // 28) * -(-height // 28)
