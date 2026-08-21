# Private-Stream Protocol — secret-derived topic + encrypted announce

> **Status:** Phase 1 — **SPECIFICATION ONLY.** No crypto is implemented yet. This document exists
> to get a **human sign-off on the crypto primitive** before any code is written (that is the whole
> point of Phase 1). Nothing here is built.
>
> **Canonical copy:** this file, in `booth-basecamp` (the protocol origin, booth#66).
> `receiver-basecamp` carries a pointer stub (receiver#69) back to this document. Both ends MUST
> implement the byte-level rules below identically or topics/keys diverge and nobody can tune in.
>
> **Scope of the three phases:**
> - **Phase 1 (this doc):** pin the wire format + pick the primitive → **human gate**.
> - **Phase 2 (Booth, booth#66):** derive topic from `Title+Pass`, encrypt the announce.
> - **Phase 3 (Receiver, receiver#69):** derive the same topic, decrypt the announce.
>
> **Related ADRs:** Booth **ADR-3** (public directory vs private topic; sets hash-topic +
> payload-encryption as the *target*), Receiver **ADR-10** (listener side of the same). Booth
> **ADR-4** / Booth **ADR-10** / Receiver **ADR-4** cover the **audio** path (HLS-over-Tor from the
> origin) — **which this protocol does NOT touch** (see §2). Identity signing is Booth/Receiver
> **ADR-5**; the canonical-bytes convention reused here comes from
> `radio_module/src/station_identity.cpp`.

---

## 1. Why — the problem this closes

Today a "private" stream is protected only by an **unguessable topic string**
(`/radio-basecamp/1/<random-or-name>/json`) carrying an **unencrypted** announce. As @vpavlin
flagged reviewing the scope PR (booth#64), that is **obscurity, not privacy**: a **relay node** on
the shard already sees every `/radio-basecamp/1/*` contentTopic *and* can read the plaintext
payload — so it can enumerate every "private" stream and pull the `.onion` URL out of it. (See
Booth ADR-3 / Receiver ADR-10 "Privacy is obscurity, not confidentiality".)

The target (adopted by the ADRs, built in Phases 2–3):

```
topic   = /radio-basecamp/1/<hash(Title+Pass)>/json
payload = encrypt(announce, key(Pass))
```

A relay node then sees only that *a* random-hash stream exists on the shard — it cannot identify it
or read its announce/URL without `Pass`.

---

## 2. What "the payload" IS — encrypt the ANNOUNCE, not the audio

**Read this before writing any encryption code.** The thing this protocol encrypts is the
**`delivery_module` announce** — the small JSON beacon Booth publishes every 15 s (ADR-2), carrying
**station metadata + the `.onion` play URL**. It is **NOT the audio**.

- **Audio** is HLS `.m3u8` + segments pulled **directly from the host's MediaMTX origin over Tor**
  (Booth ADR-4 onion hidden service; Booth ADR-10 direct-origin delivery; Receiver ADR-4 onion
  playback). It never travels over `delivery_module`. It is **out of scope here** and MUST NOT be
  touched by this work.
- **Announce** is what leaks a private station's existence-details and its play URL to relay nodes.
  Encrypting the announce hides *that a specific named station exists and where to reach it*.

> A relay that cannot read the announce cannot learn the `.onion` URL, so it cannot fetch the audio
> either — confidentiality of the announce is sufficient. Encrypting the audio segments would be
> the **wrong** work: it is redundant (Tor already tunnels them and the URL is now secret), it does
> not fit the HLS/ffplay path, and it is explicitly out of scope. **Do not encrypt the audio.**

---

## 3. Topic derivation (both ends MUST produce identical bytes)

Follows the `station_identity.cpp` sig-canonicalization convention: **canonical compact-JSON
bytes → SHA-256 → fixed encoding**.

### 3.1 Canonical preimage bytes

To make `Title+Pass` unambiguous (so `Title="ab",Pass="c"` ≠ `Title="a",Pass="bc"`) and
byte-identical across the C++ and Android/JS implementations, the preimage is **canonical compact
JSON** — the same trick station identity uses for signable bytes:

```
topicPreimage = QJsonDocument(QJsonObject{
    { "d", "radio-basecamp/private-topic/v1" },   // domain separator (also version-scopes the hash)
    { "p", Pass },                                 // exact UTF-8 as entered, Unicode-NFC-normalized
    { "t", Title }                                 // exact UTF-8 as entered, Unicode-NFC-normalized
}).toJson(QJsonDocument::Compact)
```

- `QJsonObject` serializes keys **alphabetically** → `{"d":"radio-basecamp/private-topic/v1","p":"…","t":"…"}`
  — deterministic, no separator ambiguity (JSON string-escaping disambiguates every byte).
- **Both `Title` and `Pass` MUST be normalized to Unicode NFC before insertion** so visually
  identical strings from different keyboards hash the same. (station_identity does not need this
  because it hashes raw key bytes; here the inputs are human text, so NFC is mandatory — spell it
  out in the Phase 2/3 code and the test vectors.)
- The `d` domain-separator string means this hash can never collide with the announce-signature
  hash (different object shape *and* a private-topic tag).

### 3.2 Hash + truncation + encoding

```
digest  = SHA-256(topicPreimage)                       // 32 bytes, QCryptographicHash::Sha256
trunc   = digest[0 .. 15]                               // first 128 bits (16 bytes)
segment = base32-rfc4648-lowercase-nopad(trunc)         // 26 chars, [a-z2-7]
topic   = "/radio-basecamp/1/" + segment + "/json"
```

- **Hash:** SHA-256 via `QCryptographicHash` (already the module's only hash; no new dep).
- **Truncation:** **first 128 bits.** 2^128 is uncrossable for enumeration while keeping the topic
  short; the confidentiality boundary is the *encryption* (§4), not the topic, so 128 bits is
  ample. (An 80-bit / 16-char variant is acceptable if a shorter topic is wanted; **pick one in the
  spec and lock it — 128 bits is the recommendation.**)
- **Encoding:** **base32, RFC 4648, lowercase, no padding.** Content-topic segments must be
  URL/topic-safe; `[a-z2-7]` is unambiguously safe and case-insensitive (hex would also work but is
  longer; base64 is not topic-safe). 16 bytes → `ceil(128/5)=26` chars.
- The topic keeps the `/radio-basecamp/1/` prefix, so a private stream **shares the shard** with
  public ones — exactly the ADR-3 target ("a relay node sees only that a random-hash stream
  exists").

---

## 4. Payload encryption (the announce)

### 4.1 Plaintext

The plaintext is the **existing announce JSON** — unchanged, including its identity fields. A
private stream is still **signed as today** (ADR-5): the inner announce keeps its canonical
sig-less-bytes signature (`v:2`). Order is **sign-then-encrypt** — sign the announce, then encrypt
the whole signed object; the receiver decrypts first, then verifies (§6).

### 4.2 Key derivation (from `Pass` alone)

Both ends must derive the same key from `Pass` with **no exchanged salt** (there is no side channel
— only the announce travels). So the salt is **deterministic**, derived from the (already public-ish)
`Title`:

```
salt = SHA-256("radio-basecamp/private-kdf/v1" || NFC(Title))[0 .. 15]   // 16-byte deterministic salt
key  = KDF(password = NFC(Pass), salt = salt)                            // 32-byte AEAD key
```

- **KDF must be memory-hard (Argon2id).** `Pass` is a human passphrase; a relay node that captures
  ciphertext can mount an **offline brute-force**. A fast KDF (HKDF/PBKDF2) makes weak passphrases
  trivially grindable; Argon2id raises per-guess cost by orders of magnitude.
- **Deterministic-salt caveat (document it):** a fixed salt lets an attacker precompute against a
  *known* `Title`. Argon2id's memory-hardness still applies per guess, but there is no per-user
  rainbow-table resistance. This is inherent to "derive the same key on both ends from `Pass` with
  no exchanged salt" and is acceptable given the memory-hard cost; **state it in the UI copy — a
  weak `Pass` is the weak link.**
- **Argon2id parameters are pinned into the wire contract** (both ends + any port MUST use these
  exact numbers, or keys diverge): libsodium `crypto_pwhash` **INTERACTIVE** profile —
  `opslimit = 2`, `memlimit = 67108864` (64 MiB), `alg = crypto_pwhash_ALG_ARGON2ID13`. The key is
  derived **once** per stream-start / per subscribe (not per heartbeat), so the ~50–100 ms cost is
  one-time.

### 4.3 AEAD + nonce + wire framing

```
nonce      = 24 random bytes (per announce; regenerated every heartbeat)
aad        = UTF-8(topicSegment + "|pv=1")     // the 26-char base32 segment + payload version
ciphertext = XChaCha20-Poly1305-encrypt(key, nonce, plaintext, aad)
```

- **AEAD:** XChaCha20-Poly1305 (see §5 for why over AES-GCM). The 16-byte Poly1305 tag is appended
  to the ciphertext.
- **Nonce:** **random, 192-bit (24 bytes), per message.** XChaCha's large nonce makes random nonces
  collision-safe with **no counter state** — important because Booth **persists + auto-resumes**
  (ADR-8), so a stateful 96-bit counter would risk nonce reuse across restarts. Random-XChaCha
  sidesteps that entirely.
- **AAD binds the ciphertext to its topic + version**, so a captured ciphertext cannot be replayed
  onto a different topic or spoofed as a different payload version.

**Wire envelope** — `delivery_module` single-base64s the payload bytes, so the envelope is a small
JSON object (matching the existing JSON-announce style; makes version-detection trivial):

```json
{
  "pv":  1,
  "enc": "xchacha20poly1305-argon2id",
  "n":   "<base64 nonce, 24 bytes>",
  "ct":  "<base64 ciphertext||tag>"
}
```

- `pv` = **payload/privacy version** (see §5 migration). `enc` names the primitive suite so a future
  suite can coexist and an old receiver can cleanly refuse what it can't read.
- The **decrypted `ct`** is the plaintext announce JSON of §4.1.

---

## 5. Crypto-primitive decision — **THE thing to sign off**

Qt's `QCryptographicHash` is **hash-only** (no AEAD, no KDF). So a symmetric AEAD + a memory-hard
KDF have to come from somewhere. Three candidates:

| Option | KDF | AEAD | Dependency / build impact | Verdict |
|---|---|---|---|---|
| **A. libsecp256k1** (already linked) | — | — | none new | **Not a fit.** It is a *public-key* library — ECDH key-agreement + ECDSA. We have a **shared passphrase**, not a key pair, and secp256k1 has **no cipher and no KDF**. It cannot encrypt the payload; a symmetric cipher is still required. It stays used for **identity signing** (ADR-5), unchanged. |
| **B. libsodium** (new dep) | **Argon2id** (`crypto_pwhash`) | **XChaCha20-Poly1305** (`crypto_aead_xchacha20poly1305_ietf`) | Add `libsodium` to each `flake.nix`; bundle `libsodium.so` in the portable `.lgx` `$ORIGIN` set (like `secp256k1`); Android gets a libsodium binding or a pure-JS suite. Small lib — stays under the 2 s dlopen token-handshake budget (ADR-9). | **RECOMMENDED.** One audited library covers KDF **and** AEAD **and** constant-time primitives; XChaCha's 192-bit nonce removes all nonce-state bookkeeping (matters for auto-resume, ADR-8); it has C++, and JS/RN bindings that keep the three implementations byte-compatible (Receiver's Android already ships a JS crypto stack, ADR-8). |
| **C. AES-GCM (via OpenSSL)** | PBKDF2 only (no Argon2 without another dep) | AES-256-GCM | OpenSSL is not a guaranteed module link today; GCM's **96-bit nonce** needs careful non-reuse (random-nonce collision risk ⇒ counter state ⇒ auto-resume footgun); PBKDF2 is weaker than Argon2 against passphrase brute force. | **Not recommended.** More footguns (nonce management, weaker KDF) for no upside. |

**Recommendation: Option B — libsodium (XChaCha20-Poly1305 + Argon2id).**
The `Pass` is a human passphrase, so a **memory-hard KDF is mandatory** and only libsodium gives one
cleanly; the large XChaCha nonce fits the stateless/auto-resume reality; and it keeps the C++ and
Android/JS ports on one contract. secp256k1 being "already linked" is a red herring — it is the
wrong shape of primitive for passphrase-based symmetric encryption.

> **✅ APPROVED (2026-07-28):** Option B — **libsodium XChaCha20-Poly1305 + Argon2id** signed off;
> secp256k1 stays for the announce signature. **Verified platform fact:** libsodium is **already
> bundled** in the Basecamp AppImage (`usr/lib/libsodium.so.26`) and used by `package_downloader`, so
> it is **not a new-to-Logos dependency**. The desktop modules link it build-time via pkg-config
> (`PkgConfig::sodium`, mirroring `secp256k1` — the proven in-repo pattern) and bind the
> platform-bundled `libsodium.so.26` at runtime (soname-compatible); Android adds a libsodium/JS suite.

---

## 6. Versioning, migration, backward-compat

**Public streams stay plaintext — only the private path changes.**

- **Public** streams keep announcing plaintext to `/radio-basecamp/1/directory/json` exactly as
  today. Untouched.
- **Legacy private** streams (literal unguessable topic, plaintext) keep working: a listener holding
  an old topic-string invite still subscribes to that literal topic. No flag day — the old and new
  private forms coexist on the shard.
- **New private** streams use the §3 derived topic **and** the §4 encrypted envelope.

**How a receiver tells them apart (no ambiguity):**

1. Decode the delivery payload (single-base64) → JSON.
2. If the JSON has a top-level **`pv` + `enc`** field → it is an **encrypted envelope**: derive the
   key from `Pass` (§4.2), decrypt (§4.3), then parse the inner announce and **verify its signature**
   (ADR-5). If `enc` names an unknown suite, or decryption/verify fails → **drop** (do not misparse).
3. Otherwise it is a **plaintext announce** → parse directly, as today.

- **`pv` (payload version)** lets a future primitive change (new AEAD/KDF/params) roll out without
  breaking old receivers — they refuse `pv`/`enc` they don't know rather than mis-decrypting.
- **Topic scheme** is version-tagged inside the preimage domain string
  (`radio-basecamp/private-topic/**v1**`), so a future topic-derivation change is a new domain tag,
  not a silent divergence.

**No revocation (cite ADR-3 / ADR-10).** Anyone who learns `Title+Pass` can derive the topic + key
and listen **indefinitely**; there is no key rotation or revocation. "Rotating access" = choosing a
new `Title`/`Pass` (a new topic + key) and re-inviting everyone out-of-band. Encryption changes *who
can read the announce/URL*, **not** revocability. Verification (ADR-5) is **orthogonal**: a signature
proves *who* broadcast; encryption proves the announce is *confidential*. A private stream is
**signed *and* encrypted** (sign-then-encrypt, §4.1).

---

## 7. Verification — MANDATORY headless round-trip test (Phase 2 & 3 must ship it)

The **cheapest real proof** the two ends agree, before any UI exists. **Phases 2 and 3 MUST ship
this test green** (Booth via `logoscore` headless; Receiver via its test path + the Android/JS port).
It is the confidentiality-analogue of `StationIdentity::selfTest()`.

**Round-trip (both ends, one fixed `(Title, Pass)`):**

1. Booth derives `topic_b` (§3) and `key_b` (§4.2); encrypts a known announce → envelope `E`.
2. Receiver **independently** derives `topic_r` and `key_r` from the same `(Title, Pass)`; decrypts
   `E` → `announce'`.
3. **Assert** `topic_b == topic_r` (byte-identical topic string) **and** `announce' == announce`
   (round-trip), **and** the inner signature verifies (ADR-5).

**Negative cases (must all fail closed):**

4. **Wrong `Pass`** → AEAD tag rejects, decryption fails, announce dropped (not misparsed).
5. **Tamper** — flip one ciphertext byte → tag rejects.
6. **Cross-topic replay** — feed `E` under a different topic segment → AAD mismatch rejects.

**Golden cross-impl vectors (lock byte-compatibility across the 3 implementations —**
**booth C++, receiver C++, receiver Android/JS, per ADR-8):**

7. A fixed `(Title, Pass)` → **expected `topic` string** + **expected 32-byte `key` (hex)** +
   (with a fixed nonce) **expected `ct` (base64)**, committed as test vectors. All three
   implementations assert byte-identity against the same vectors — the same discipline that keeps
   the station-identity signing contract in lockstep.

**Reference vectors** (baked into `StationCrypto::selfTest()`; the receiver C++ + Android/JS ports
MUST reproduce them): `Title = "Parallel Society Radio"`, `Pass = "correct horse battery staple"` →
- `topic = /radio-basecamp/1/rdbdcntqiiyuvqrx3c4uuukcuu/json`
- `key   = 0206f36f316dfac61900a84f3b6d8860e9bd5443851646e25bc8bc2acd2d5ff1`
- with nonce = 24×`0x07` over a fixed announce, `ct (base64) = JATbvqazwSc1Juu0XKqw0e+4lulqBI4WhBJeOcMwTKRSeUkWqBx7HwlpHF1/ULUwfgaIsngt7k+0DF8kVZcsNEBaqIyWGhUdFDHqEX263olhnMcGdomUj9REcs8UL46xKYPR`

---

## 8. Phase gate

- [x] **Phase 1 — this spec.** Crypto primitive **signed off** (§5: libsodium / XChaCha20-Poly1305 +
      Argon2id).
- [x] **Phase 2 — Booth (booth#66):** topic derivation + announce encryption + §7 test **GREEN**.
      Shared `station_crypto.{h,cpp}` + `radio_plugin` wiring + `radio_ui` passphrase field.
- [x] **Phase 3 — Receiver (receiver#69):** matching derivation + decryption + §7 test (C++). The
      Android/JS port reproduces the golden vectors — tracked separately.

> The full end-to-end path (real delivery node + Tor + two machines + GUI) is **wetware** — see the
> 🧫 steps on booth#66 / receiver#69. The byte-level crypto is proven headlessly by §7.
