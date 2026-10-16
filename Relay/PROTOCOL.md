# iGhostVT relay protocol, version 1

The relay lets a device reach a host that is not on its local network. It
splices TCP and nothing else: the remote-access TLS (TLS 1.2 PSK, see
`Shared/Remote/RemoteTLS.swift`) runs end to end between the app and the
host, and the relay only ever sees its ciphertext.

One TCP port (46405 by default). The first byte of a connection says what
it is:

- `0x16`: a TLS record — an app connecting to a host. Routed by SNI.
- `I` (`IGVR`): the control protocol, spoken by hosts and by apps listing
  hosts.

Anything else is closed.

## Keys

The relay generates one P-256 key pair when it first starts. It keeps the
public key (`/data/relay.json`); the private key goes only into the
configuration file it writes for people to import (`.vtrpsc`). Every device
that imports that file signs with the private key, so the relay checks
membership without ever holding a secret worth stealing.

Each host also has its own P-256 key (the "host key"), made by the host. The
first registration of a host id binds that id to the host key
(`/data/hosts.json`); later registrations must sign with the same key, and
only that key can accept a connection for the host.

Signatures are ECDSA over SHA-256, DER-encoded (CryptoKit's
`P256.Signing.ECDSASignature.derRepresentation`, Go's `ecdsa.VerifyASN1`),
base64 (standard alphabet, padded) in JSON. A host key travels as its
SubjectPublicKeyInfo DER (CryptoKit's `P256.Signing.PublicKey.derRepresentation`,
Go's `x509.ParsePKIXPublicKey`), base64.

The signed message is UTF-8 text, fields joined by `\n`:

```
ighostvt-relay-v1
<role>
<relayID>
<nonce, base64; empty for accept>
<parameter: hostID for host, ticket for accept, empty for list>
```

## The configuration file (`.vtrpsc`)

JSON, UTType `wiki.qaq.ighostvt.relay-config`:

```json
{
  "format": "ighostvt-relay",
  "version": 1,
  "name": "home",
  "endpoint": "relay.example.com:46405",
  "relayID": "6F1C…",
  "key": "<P-256 private key, raw 32-byte scalar, base64>"
}
```

`endpoint` is `host:port`; an IPv6 address is bracketed. `version` is the
file format's, not the protocol's; an app refuses a version it does not know.

## App → host: a data connection

1. The app opens TCP to the relay and starts the TLS handshake it would
   start with the host directly, with SNI set to the host id, lower-case.
2. The relay reads the first TLS record within 5 s: a 5-byte header, then at
   most 16384 bytes. It must be one whole ClientHello with exactly one
   `host_name` in its `server_name` extension; with a trailing dot removed
   and lower-cased that name must be a UUID. A ClientHello spread over more
   than one record is refused.
3. If that host is registered, the relay makes a ticket (16 random bytes,
   base64url, no padding) and sends the host `{"type":"incoming",
   "ticket":…, "from":"<client address>"}`. The ticket dies after 10 s, or as
   soon as the client goes away.
4. The host connects back and accepts the ticket (below). The relay writes
   every byte it has read from the client so far to the host, then splices
   the two connections both ways.
5. No such host, no accept in time, a bad SNI: the relay closes the
   connection. The app sees its TLS handshake fail.

## Control connections

The client writes `IGVR` and one byte, the protocol version (1). The relay
answers at once with its hello frame, before reading anything else:

```json
{"relay":"ighostvt-relay","version":1,"relayID":"…","nonce":"<32 random bytes, base64>"}
```

If the byte the client sent is not the relay's version, the relay follows
the hello with `{"ok":false,"reason":"version"}` and closes. A client that
reads a hello whose `version` is not its own stops too. Versions must be
equal; there is no negotiation.

Every frame after the magic is `[u32 big-endian length][JSON object]`, at
most 64 KiB. A reader reads exactly 4 bytes and then exactly that length —
after an `accept` is granted, the bytes that follow are no longer frames.

A connection that has not sent its request within 5 s is closed.

The client's first frame names its `role`:

### `host`

Sent after reading the hello (it signs the nonce):

```json
{"role":"host","hostID":"…","name":"Office Mac","appVersion":"1.4.0",
 "hostKey":"<SPKI DER, base64>","sig":"<relay key>","hostSig":"<host key>"}
```

`sig` and `hostSig` sign the same message (role `host`, the nonce, the host
id). Answered with `{"ok":true}` or `{"ok":false,"reason":…}`:

| reason | meaning |
|---|---|
| `version` | protocol versions differ |
| `auth` | `sig` does not verify: not a member of this relay |
| `hostKey` | the host id is bound to another host key, or `hostSig` does not verify |
| `full` | the relay holds as many hosts as it allows |
| `invalid` | anything malformed |

After `ok` the connection stays open. The relay sends `incoming` frames.
The host sends `{"type":"ping"}` every 90 s and the relay answers
`{"type":"pong"}`; a relay that hears nothing from a host for 200 s drops
it, a host that hears nothing for 180 s reconnects. Both ends also run TCP
keepalive.

A host id registered again with the same host key replaces the old
connection: the relay sends the old one `{"type":"superseded"}` and closes
it. A host that receives `superseded` does not reconnect by itself —
another machine is running with its identity.

### `accept`

Sent without waiting for the hello (the ticket is fresh on its own; this
saves a round trip). The client still reads the hello before the answer.

```json
{"role":"accept","ticket":"…","hostSig":"<host key, message with empty nonce and the ticket>"}
```

Answered with `{"ok":true}` — every byte after that frame is the client's
TLS stream — or `{"ok":false,"reason":"ticket"}` (unknown, expired, or the
client left) and closed. Only the host the ticket was issued to can sign it.

### `list`

Sent after reading the hello:

```json
{"role":"list","sig":"<relay key>"}
```

Answered with `{"ok":true,"hosts":[{"id":"…","name":"…","appVersion":"1.4.0","since":1760000000}]}`
and closed.

### `drop`

The drop zone: files any member puts on the relay for any member to take.
Sent after reading the hello:

```json
{"role":"drop","sig":"<relay key; role drop, the nonce, empty parameter>"}
```

Refused like `list` (`auth`), with `full` when 32 drop sessions are open,
and with `invalid` when the relay runs with the drop zone off — which is
also what a relay older than the drop zone answers to the unknown role, so
a client says the same thing about both. Admitted:

```json
{"ok":true,"ttl":1800,"fileBytes":4294967296,"totalBytes":4294967296}
```

Requests then follow one at a time on the same connection, each a frame
with an `op`, each answered by a frame. A refusal of one request is
`{"ok":false,"reason":…}` and the session goes on, except where noted.
A session that sends nothing for 60 s — between requests, or inside an
upload's stream — is closed; a download is cut when the client takes no
64 KiB for 60 s. A session takes no new request an hour after it was
admitted, so no connection holds its files forever, and a key rotation
ends every drop session at once.

| op | request | answer |
|---|---|---|
| `ls` | — | `{"ok":true,"files":[entry…]}` (absent when empty) |
| `put` | `name`, `size`, `mode`, `mtime`, `encoding`, `fingerprint` — or `id` alone to resume | `{"ok":true,"id":…,"offset":K}`, then the stream (below) |
| `get` | `id`, `offset` | `{"ok":true,"id":…,"offset":…,"stored":N}`, then bytes `offset`…`N` raw |
| `rm` | `id` | `{"ok":true,"id":…}` |

An entry is the file's manifest row:

```json
{"id":"<uuid>","name":"build.log","size":17488895,"stored":217744,
 "encoding":"zstd","mode":420,"mtime":1735787040,"sha256":"<hex>",
 "fingerprint":"v1:z10507l3:<hex>","created":1760000000,"complete":true,
 "expires":1760001800}
```

`size`, `mode`, `mtime` and `sha256` are the uploader's word about the
file itself, and `fingerprint` (optional, at most 128 bytes of lower-case
letters, digits and colons) is a mark of its own the relay keeps and lists
but never reads — the CLI's names its zstd version and level and the
SHA-256 of the file's first MiB, and it compares that before resuming a
partial upload; `stored` is the bytes the relay holds. The relay never decodes
anything: what it stores is what the uploader streamed, and `encoding`
(`zstd` or `none`) tells the downloader how to read it. `expires` is absent
while the file is held (below).

**Upload.** The relay makes the id (a random UUID; the file is stored under
it, never under its name) and answers how many stored bytes it already has:
0 for a new file, more for a resumed one. The client then streams the rest
of the encoded file as chunks — `[u32 big-endian length][bytes]`, at most
1 MiB each — ends with a zero length, and sends
`{"op":"commit","sha256":"<64 lower-case hex>"}`, answered
`{"ok":true,"id":…,"stored":N}`. Only a committed file can be read
(`incomplete` otherwise). A chunk that would take the file past `fileBytes`
is answered `size` and the file is removed; past `totalBytes`, or into the
last GiB of free disk, `full` and the partial file is kept for a resume.
Both end the session, as does a chunk longer than 1 MiB (`invalid`). A
resume (`put` with `id`) needs an uncommitted file no connection is
uploading (`busy` otherwise); the stream picks up at `offset`, so the
client must produce the same bytes again — the CLI compresses on one thread
at a fixed level for exactly this.

`name` is one path component of at most 255 bytes of UTF-8: no `/` or `\`,
not `.` or `..`, no control character and none of the format characters
that reorder or hide text (U+200B–U+200F, U+202A–U+202E, U+2066–U+2069,
U+2028, U+2029, U+FEFF). `mode` is at most `0777`, `mtime` within 10¹¹
seconds of the epoch. Anything else is `invalid`. Together these keep an
`ls` of the most files at the longest names within one frame.

**Expiry.** A file is *held* by every open connection that put or got it,
and goes 30 minutes (`ttl`) after the last of them closed. `ls` holds
nothing, so listing keeps no file alive. `rm` removes a file at once unless
it is being uploaded (`busy`); a download already under way finishes. The
relay empties the whole zone when it starts and when it stops: nothing in
it outlives the process.

Reasons: `unknown` (no such id), `incomplete`, `busy`, `size`, `full`,
`invalid`.

## Liveness

Every connection the relay holds — both legs of a splice and every control
connection — has TCP keepalive (10 s idle, 5 s interval, 3 probes) and a
TCP user timeout of 25 s. When either leg of a splice ends, by EOF, error
or timeout, the relay closes both; nothing is left half-open.

## Limits

64 hosts; 32 pending tickets per host; 512 splices; 64 connections that
have not yet produced an SNI; data connections rate-limited per source
address (60 per 10 s by default, `RELAY_RATE_PER_IP`); 32 drop sessions, 64
files and 4 GiB stored in the drop zone (`RELAY_DROP_BYTES`, one file at most
`RELAY_DROP_FILE_BYTES`), never into the disk's last GiB. A splice reads from one side only after the write to
the other has completed, so a slow reader slows its writer instead of
filling the relay's memory.
