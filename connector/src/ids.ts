/** Stable note id for a Plaud recording — mirrors RiffCore NoteID.forPlaud and riffdesk/ids.py. */
export function noteIdForPlaud(plaudId: string): string {
  const data = new TextEncoder().encode("plaud:" + plaudId);
  const fnv = (seed: bigint): bigint => {
    let h = seed;
    for (const b of data) {
      h ^= BigInt(b);
      h = (h * 0x100000001b3n) & 0xffffffffffffffffn;
    }
    return h;
  };
  const h1 = fnv(0xcbf29ce484222325n);
  const h2 = fnv(0x84222325cbf29ce4n);
  const bytes = new Uint8Array(16);
  for (let i = 0; i < 8; i++) {
    bytes[i] = Number((h1 >> BigInt(56 - 8 * i)) & 0xffn);
    bytes[8 + i] = Number((h2 >> BigInt(56 - 8 * i)) & 0xffn);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
