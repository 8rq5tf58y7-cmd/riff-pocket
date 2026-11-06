"""Stable note ids shared with the iPhone app (mirror of RiffCore NoteID.forPlaud)."""

import uuid


def _fnv1a64(data: bytes, seed: int) -> int:
    h = seed
    for b in data:
        h ^= b
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def note_id_for_plaud(plaud_id: str) -> str:
    """The same Plaud recording gets the same note id on the phone and the desktop."""
    data = ("plaud:" + plaud_id).encode("utf-8")
    out = bytearray(
        _fnv1a64(data, 0xCBF29CE484222325).to_bytes(8, "big")
        + _fnv1a64(data, 0x84222325CBF29CE4).to_bytes(8, "big")
    )
    out[6] = (out[6] & 0x0F) | 0x50
    out[8] = (out[8] & 0x3F) | 0x80
    h = out.hex().upper()
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def new_id() -> str:
    return str(uuid.uuid4()).upper()
