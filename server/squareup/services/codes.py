"""Human-readable secret codes: Crockford Base32 without I, L, O, U, so they're unambiguous when
read aloud or typed. Only a code's SHA-256 is ever stored. Lookups accept any case, spaces, and
dashes, and the usual misreadings (O → 0, I/L → 1)."""

from __future__ import annotations

import secrets

CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
#: Group invitations: 20 characters = 100 bits.
GROUP_CODE_LENGTH = 20
#: Temporary-room invitations: 12 characters = 60 bits, short enough to read across a table.
#: Guessing is bounded by the rate limit, the invitation's expiry, and revocation.
ROOM_CODE_LENGTH = 12


def new_code(length: int) -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(length))


def normalize_code(text: str, length: int) -> str | None:
    if len(text) > 64:
        return None
    cleaned = text.upper().replace("-", "").replace(" ", "").replace("O", "0").replace("I", "1").replace("L", "1")
    if len(cleaned) != length or any(character not in CODE_ALPHABET for character in cleaned):
        return None
    return cleaned


def display_code(code: str) -> str:
    return "-".join(code[index : index + 4] for index in range(0, len(code), 4))
