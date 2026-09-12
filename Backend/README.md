# ehviewer-webd

A read-only web service for an EhViewer library that has been synced to a Linux
machine. It walks the synced directory, reads the per-gallery `.ehviewer`
metadata files and the exported SQLite snapshots, and serves the result over
HTTP so a browser or a Flutter client can browse and read.

Nothing in the synced tree is ever written to.

---

## What it reads

The layout is the one EhViewer produces; the parser was written against the
upstream source, not against observed behaviour.

```
<root>/
├── download/
│   └── <gid>-<title>/
│       ├── .ehviewer          gallery metadata (SpiderInfo)
│       ├── 00000001.jpg       page 1 (8-digit zero padded, 1-based)
│       ├── 00000002.png
│       └── ...
└── data/
    └── <timestamp>.db         snapshot from EhViewer's "export data"
```

`data/` does not appear on its own. The snapshot is a manual action on the
phone — **设置 → 高级 → 导出数据** (`ExportDataPreference`) — and until someone
taps it, the directory is empty and every title, category, rating and label
that lives only in the database is unavailable. See
[Derived tags](#derived-tags) for what the service can still offer without one.

Three facts about the format are worth knowing, because each one is a trap:

**`.ehviewer` is a line-oriented text file with two versions.** A version 1 file
has no `VERSION` prefix and no dedicated start-page line: its first line does
double duty. Everything after the token shifts up by one line relative to
version 2. The parser handles both.

**The start page is a fold, not a hex decode.** Each character multiplies the
accumulator by 16, and only `[0-9a-f]` characters add a value. A non-hex
character therefore still shifts: `"12-34"` parses as `0x12034`, not `0x1234`.
This mirrors `SpiderInfo.getStartPage()` exactly.

**The page count in `.ehviewer` is advisory.** An interrupted download, a
`STATE_UPDATE` row or a hand-edited folder all make it disagree with the files
on disk. The filesystem always wins, and the disagreement is reported as an
`page_count_mismatch` anomaly rather than hidden.

### What is *not* available

* **Tags.** The export action copies exactly eight tables and `Gallery_Tags` is
  not among them, so per-tag filtering is impossible from a snapshot alone.
  `/api/v1/meta` advertises `features.tags = false` so a client can hide the
  filter instead of offering one that never matches.
* **`SIMPLE_LANGUAGE` is frequently NULL**, because the phone derives it from
  tags. The service falls back to deriving the language from the title using a
  port of `GalleryInfo.S_LANG_PATTERNS`, in the original pattern order.
* **Category names.** The `CATEGORY` enum lives in an `EhUtils` class that is
  not in the app repository (it comes from an AAR dependency). The service
  therefore returns the raw integer and makes no claim about its meaning; use
  `scan` to see the real value distribution for your library.

---

## Build

Requires Go 1.24 or newer. No CGO.

```sh
go build -o ehviewer-webd ./cmd/ehviewer-webd
go test ./...
```

## Run with Docker

`docker-compose.yml` runs it as a non-root distroless container with the synced
tree mounted read-only.

```sh
mkdir -p deploy
cp deploy/token.example deploy/token
openssl rand -base64 32 > deploy/token   # or: ehviewer-webd gentoken
chmod 600 deploy/token

EHW_SYNC_DIR=/srv/ehviewer-sync/EhViewer \
EHW_UID=$(id -u) EHW_GID=$(id -g) \
docker compose up -d
```

`deploy/config.json` already uses container paths (`/sync`,
`/var/lib/ehviewer-webd`) and listens on `0.0.0.0:8080`; the compose file
publishes it on `127.0.0.1:8080` so the frp client on the same host can reach
it without exposing it directly.

### Two settings that will bite if ignored

**`EHW_UID` / `EHW_GID` must match the owner of the synced files.** The
distroless image runs as uid 65532, but a Syncthing-managed tree is usually
owned by your own uid with mode `0640` or `0600`. Without matching, the
container starts, reads nothing, and reports an empty library — with no error,
because "no galleries found" is a legitimate state.

**The sync mount is `:ro`, and that is load-bearing.** It is a kernel-level
guarantee that the service cannot write into the tree Syncthing manages, on top
of the application never trying to. Do not relax it to debug something; if the
service needed to write there, that would be the bug.

### Why distroless

`modernc.org/sqlite` is pure Go, so `CGO_ENABLED=0` produces a fully static
binary and the runtime image needs no libc, no shell and no package manager.
The image is a single ~11 MB binary on a ~2 MB base.

The compose file also sets `read_only: true`, `cap_drop: ALL`, and
`no-new-privileges`, so the named volume is the only writable path.

---

## Quick start

```sh
# 1. Look at what is actually there before configuring anything.
./ehviewer-webd scan -root /srv/ehviewer-sync/EhViewer

# 2. Generate an access token.
./ehviewer-webd gentoken > /etc/ehviewer-webd/token
chmod 600 /etc/ehviewer-webd/token

# 3. Write a config (start from the annotated sample).
./ehviewer-webd sampleconfig > /etc/ehviewer-webd/config.json

# 4. Run.
./ehviewer-webd serve -config /etc/ehviewer-webd/config.json
```

`scan` is the recommended first step. It prints the gallery count, page count,
page-size distribution, the spread of `.ehviewer` versions, the real category
values, and every directory it refused to index along with the reason. Those
numbers are what tell you whether the layout matches what the service expects.

### Subcommands

| Command | Purpose |
|---|---|
| `serve` | Run the HTTP service (default when no subcommand is given). |
| `scan` | Scan once, print a summary. `-json` for machine-readable output. |
| `gentoken` | Print a fresh random token. `-bytes N` (default 32). |
| `sampleconfig` | Print an annotated example config. |
| `version` | Print the version. |

### Flags

`serve` and `scan` accept:

| Flag | Meaning |
|---|---|
| `-config FILE` | JSON config file. Optional; a missing file is not an error. |
| `-root DIR` | Synced EhViewer directory. Overrides `sync.roots`. |
| `-listen ADDR` | Bind address. Overrides `listen`. |
| `-data-dir DIR` | Writable state directory. Overrides `data_dir`. |
| `-log-level LVL` | `debug`, `info`, `warn`, `error`. |

Precedence is defaults, then config file, then flags.

---

## Configuration

JSON, with `//` comments and a UTF-8 BOM both tolerated. Unknown keys are
**rejected**, so a typo cannot silently leave a default in place.

```jsonc
{
  "listen": "127.0.0.1:8080",
  "data_dir": "/var/lib/ehviewer-webd",

  "sync": {
    "roots": ["/srv/ehviewer-sync/EhViewer"],
    "download_dirs": ["download"],   // candidates, relative to a root
    "db_dirs": ["data"],
    "db_policy": "latest",           // or "merge"
    "rescan_interval": "30m",
    "watch": true,
    "watch_debounce": "2s",
    "skip_symlinks": true,
    "max_galleries": 500000
  },

  "auth": {
    "mode": "token",                 // or "none" (loopback only)
    "token_file": "/etc/ehviewer-webd/token",
    "session_ttl": "720h",
    "secure_cookies": true
  },

  "proxy": {
    "trusted_proxies": ["127.0.0.1/32"],
    "client_ip_header": "X-Forwarded-For"
  },

  "limits": {
    "read_header_timeout": "10s",
    "read_timeout": "60s",
    "write_timeout": "5m",
    "idle_timeout": "120s"
  },

  "thumb": { "enabled": true, "max_dim": 480, "quality": 82, "workers": 2 },
  "logging": { "level": "info", "format": "text" }
}
```

### Startup refuses to proceed when

* **`data_dir` is inside a sync root.** The index and thumbnail cache would be
  synced back to the phone, and Syncthing would start fighting over them.
* **`auth.mode` is `"none"` on a non-loopback listener.** Behind an frp tunnel
  a non-loopback listener is world-reachable, so serving the library
  unauthenticated is refused rather than warned about.
* **`auth.mode` is `"token"` with no token configured.**

### `download_dirs` and `db_dirs`

These are candidates, tried in order, relative to each root unless absolute.

`download_dirs` is configurable because `Settings.getDownloadLocation()`
returns a `UniFile` the user may have pointed anywhere; the service cannot
assume `download`. If none of the candidates exist, the root itself is used, so
pointing `sync.roots` directly at a synced `download` directory also works.

### `db_policy`

* `latest` — use only the newest snapshot. Predictable, and the default.
* `merge` — fold every snapshot oldest to newest, newer rows winning per gid.
  Recovers galleries that a newer export dropped, at the cost of possibly
  resurrecting a row that a newer export deliberately removed.

---

## HTTP API

All routes except `/healthz` and `/readyz` require a session cookie.

### Authentication

| Method | Path | Notes |
|---|---|---|
| `POST` | `/api/v1/auth/login` | Body `{"token":"..."}`. Sets an `HttpOnly; Secure; SameSite=Lax` cookie with no `Domain` attribute. Body is capped at 4 KB. |
| `POST` | `/api/v1/auth/logout` | Clears the cookie. |
| `GET` | `/api/v1/auth/me` | Reports whether the session is valid and when it expires. |

The session is a self-contained HMAC-SHA256 signed payload, so a restart does
not log you out as long as `data_dir` persists. The signing key lives in
`<data_dir>/session.key` with mode `0600`.

A request without a valid session gets a bare `401`: no body, no
`WWW-Authenticate` header, nothing to tell a scanner that the route exists.

### Data

| Method | Path | Notes |
|---|---|---|
| `GET` | `/healthz` | Liveness. Unauthenticated, and deliberately does not disclose library size. |
| `GET` | `/readyz` | Readiness plus gallery count. |
| `GET` | `/api/v1/meta` | Freshness, feature flags, index statistics, warnings. |
| `GET` | `/api/v1/facets` | Every filter dimension with counts: labels, languages, categories, availability, and the directory-derived artists, groups, series, events and editions. |
| `GET` | `/api/v1/galleries` | Paged list. |
| `GET` | `/api/v1/galleries/{gid}` | One gallery with its page list. |
| `GET` | `/api/v1/events` | Server-sent event stream of index changes. |
| `GET` | `/img/{gid}/{index}` | Original page image. |
| `GET` | `/thumb/{gid}` | Cover thumbnail, JPEG. |
| `POST` | `/api/v1/admin/reindex` | Force a rebuild. Loopback callers only. |

#### `GET /api/v1/galleries`

| Parameter | Meaning |
|---|---|
| `q` | Case-insensitive substring over title, Japanese title, uploader, label, token, gid, and the derived tags. |
| `label` | Exact label match. |
| `language` | Exact `simple_language` match (for example `ZH`). |
| `category` | Integer category. |
| `availability` | `ok`, `degraded` or `missing`. |
| `artist` | Repeatable. Derived artist or circle. |
| `group` | Repeatable. Derived scanlation group. |
| `series` | Repeatable. Derived parody or source work. |
| `event` | Repeatable. Derived event tag, for example `C85`. |
| `edition` | Repeatable. Derived release marker, for example `Digital`. |
| `sort` | `time_desc` (default), `time_asc`, `title`, `rating_desc`, `pages_desc`, `gid_desc`, `random`. |
| `limit` | Page size, default 60, capped at 500. |
| `cursor` | Opaque token from `next_cursor`. |

Tag parameters are repeated rather than comma-joined (`?artist=a&artist=b`), and
values are compared case-insensitively. Within one dimension they are OR-ed —
picking two artists means "either" — while different dimensions are AND-ed.
Empty values are ignored, so an unchecked chip cannot become a filter that
matches nothing.

Pagination is cursor-based, not offset-based. The cursor encodes the offset and
a fingerprint of the filter set, so replaying one against a different query is
rejected with `400` instead of silently skipping rows.

```json
{
  "items": [
    {
      "gid": 1234568,
      "token": "tok2",
      "title": "Second Gallery (Chinese)",
      "title_source": "db",
      "dir_name": "1234568-Second Gallery (Chinese)",
      "artists": ["Some Circle"],
      "groups": ["Some Group"],
      "series": ["Source Work"],
      "events": [],
      "editions": ["Digital"],
      "category": 1,
      "rating": 4.5,
      "simple_language": "ZH",
      "label": "默认",
      "state": 3,
      "download_time_ms": 1700000002000,
      "pages_expected": 3,
      "pages_found": 3,
      "total_bytes": 315,
      "cover_url": "/thumb/1234568?v=1789132065867",
      "cover_kind": "firstpage",
      "availability": "ok",
      "anomalies": [],
      "meta_source": "db",
      "on_disk": true
    }
  ],
  "next_cursor": "",
  "total": 7,
  "limit": 60,
  "indexed_at_ms": 1789132082438,
  "snapshot_at_ms": 1789132065910
}
```

The list projection deliberately omits the page array: per-page detail for a
thousand galleries would be megabytes of JSON that a grid never renders.

### Derived tags

The synced tree contains no tag data. The exported snapshot copies eight tables
and `Gallery_Tags` is not one of them, and Syncthing syncs files rather than the
phone's database, so a library that has never been exported has no tags at all.

What it does have is the directory name, and EhViewer builds that name from the
site title verbatim (`FileUtils.sanitizeFilename` only removes characters the
filesystem rejects). The service therefore parses the title convention

```
[Circle (Artist)] Title (Parody) [Language] [Scanlation group] [Digital]
```

into five filterable dimensions:

| Dimension | Source | Example |
|---|---|---|
| `artists` | Leading `[...]` groups | `balmos`, `Kemotsubo (Shintani)` |
| `groups` | Trailing `[...]` groups that are not markers | `黑曜石汉化组`, `同文城` |
| `series` | Parenthesised groups that are neither an event code nor a marker | `Kung Fu Panda`, `Warzard` |
| `events` | Leading `(...)` groups shaped like an event code | `C85`, `FF35` |
| `editions` | Marker groups | `Digital`, `Complete` |

Three rules matter, and all three came out of real libraries:

* **A title is cleaned only when it came from a directory name.** A snapshot
  title is the site's own value and is returned verbatim. The raw name stays in
  `dir_name` either way, and `title_source` says which one was used.
* **Facet keys are case-folded; labels are not.** The same artist spelled
  `Koukyuu Denim ni wa Shichimi o Kakenaide (Futee)` and `Koukyuu denim ni wa
  shichimi o kakenaide (futee)` is one bucket with a count of two, labelled with
  a spelling the library actually uses. Filtering is case-insensitive, so either
  spelling matches.
* **Language markers are dropped, not filed.** `[Chinese]` does not become an
  edition: `simple_language` already answers that question from the same title,
  and two sources for one filter drift apart the moment one changes.

The dimensions are heuristics, so the parser resolves ambiguity in one
direction: a group that might be metadata stays in the title. A marker left in
a title costs a bracketed suffix, while a title fragment filed under the wrong
dimension is wrong in the filter list with no way for a user to tell.

`features.tags` in `/api/v1/meta` still reports `false` for E-Hentai's own tags —
those require a snapshot. These derived dimensions need no flag: an empty facet
list already says a dimension has nothing in it.

#### `GET /api/v1/galleries/{gid}`

Adds `pages_detail` (index, filename, extension, size, mtime, URL),
`spider_info`, and `prev_gid`/`next_gid` for a reader's "next book" affordance.

`spider_info.present` is `false` when there is no usable `.ehviewer`. The
preview counts are never synthesized — a client that uses them for layout would
silently render the wrong thing if they were invented.

#### `availability` and `meta_source`

| `availability` | Meaning |
|---|---|
| `ok` | Directory present, every expected page found, no anomalies. |
| `degraded` | Browsable, but something is off. See `anomalies`. |
| `missing` | Either a DB row with no directory on disk (usually Syncthing has not caught up), or a directory with no usable pages. |

| `meta_source` | Meaning |
|---|---|
| `db` | Metadata merged from a snapshot. |
| `local_only` | No DB row; the title comes from the directory name. |
| `orphan_db` | DB row with no directory. |

Anomaly codes: `page_count_mismatch`, `page_gap`, `empty_gallery`,
`gid_mismatch`, `dir_unparsable`, `spiderinfo_invalid`, `spiderinfo_missing`.

#### Images

`/img/{gid}/{index}` uses `http.ServeContent`, so `Range`,
`If-Modified-Since` and `If-None-Match` all work and `Content-Length` is
correct — byte-range seeking in a reader behaves.

Response headers include `ETag`, `Cache-Control: private, max-age=31536000,
immutable`, `X-Content-Type-Options: nosniff` and `Content-Disposition: inline`.

`/thumb/{gid}` renders page 1 down to `thumb.max_dim` and caches it as JPEG
under `data_dir/thumbs`. If the first page is undecodable or oversized it falls
back to a later page, and if every page fails it returns a structured error
rather than an image. Decoding is guarded by `image.DecodeConfig` with a
64-megapixel and 20000-pixel-per-axis ceiling before any bitmap is allocated,
and concurrent renders are capped by `thumb.workers`.

---

## Deployment notes

### The synced tree is only ever read

Snapshots are opened with `mode=ro&immutable=1&_query_only=true`, so SQLite
neither writes to them nor creates `-wal`/`-shm` siblings inside the synced
tree, and it skips locking entirely. The scanner opens files read-only. The
index and thumbnail cache live under `data_dir`, which the config validator
requires to be outside every sync root.

### Syncthing

Set the Linux side to **Receive Only**. That is a hard barrier against anything
this service could ever write back.

Recommended `.stignore` entries on the phone, to cut sync traffic and the
filesystem-event noise the watcher would otherwise process:

```
.stfolder
.stversions
.stignore
logcat
crash
parse_error
image
~syncthing~*
*.tmp
```

`image/` is EhViewer's DiskLruCache. Its journal changes constantly and
produces `.sync-conflict-*` files, and this service does not need it: covers
come from page 1. Ignoring it is the simpler, more stable choice.

The watcher ignores Syncthing's temporary files, conflict copies, `.stfolder`,
`.stversions` and editor swap files, so a transfer produces one debounced
rebuild rather than thousands.

### Behind a reverse proxy

The service binds loopback and expects the VPS reverse proxy to be the only
thing reaching it.

Two proxy settings are not optional in practice:

**Turn buffering off for `/api/v1/events`.** This is the one that fails
silently. A proxy with buffering on accepts the SSE connection, returns `200`,
and then holds the stream: the client sees a healthy connection that never
produces an event, with no error in any log on either side.

* Nginx: `proxy_buffering off;` plus `chunked_transfer_encoding on;`, and
  `proxy_read_timeout` well above the 15s heartbeat.
* Caddy: `flush_interval -1`.

The server does the part it can control: it writes a `hello` event immediately
and flushes, so a client can tell "connected and quiet" from "connected but
buffered" by whether the first event arrived at all. The `X-Accel-Buffering: no`
response header also tells Nginx not to buffer this specific response.

**Set the real client IP.** If the proxy does not send a trustworthy
`X-Forwarded-For`, every request appears to come from the proxy. Anything
IP-based then misbehaves in the worst possible direction: one noisy client
would look like everyone. Configure `proxy.trusted_proxies` to match, and
configure the proxy so it does not forward a client-supplied header.

Image bodies travel over the tunnel, so give the proxy and the tunnel generous
read timeouts; the default 60s is not enough for a large page on a slow link.

**Note the server's own timeouts.** `WriteTimeout` is deliberately not taken
from config: one global write deadline cannot serve both a page image that may
legitimately take minutes on a slow tunnel and an SSE stream that must stay open
indefinitely. Handlers bound themselves with `http.ResponseController` instead,
so `limits.write_timeout` in the config is currently unused and the image
handler applies its own 10-minute deadline.

### Live updates

`/api/v1/events` streams what the filesystem watcher finds, so a client does not
have to poll. The payload is a delta, not a notification to re-fetch everything:

```
event: hello
data: {"index_at_ms":1789135697749,"snapshot_at_ms":0,"galleries":23}

event: index_changed
data: {"index_at_ms":1789135720613,"galleries":24,"added":[9999998],"reason":"filesystem_change"}

: keepalive
```

Design points worth knowing:

* **`hello` arrives immediately.** It is how a client distinguishes a working
  stream from one a buffering proxy has swallowed.
* **A gallery is reported changed only if something the client renders moved.**
  A rebuild re-stats every page, so per-file mtimes change constantly; comparing
  whole records would report every gallery as changed on every rescan and wake
  every client for nothing.
* **The id lists are capped at 512 and `truncated` is set past that.** A client
  must then refetch rather than applying a partial delta.
* **A full queue drops events rather than blocking.** A subscriber that stops
  reading loses updates; a rebuild is never stalled by a dead client. The client
  reconciles on its next refetch.
* **The stream ends after 30 minutes by design**, so the session is re-checked
  and intermediaries get a clean connection. A client is expected to reconnect;
  it also sends a `: reconnect` comment first.
* **`features.sse` in `/api/v1/meta` reflects whether a hub actually exists**,
  so a client can report "no live updates" instead of waiting on a stream that
  will never produce anything.


---

## Architecture

```
Syncthing ──► /srv/ehviewer-sync/EhViewer
                        │ read-only
                        ▼
              ┌──────────────────────────────────────┐
              │ ehviewer-webd                        │
              │                                      │
              │  scan ──► index (in memory) ◄── dbexport
              │    ▲            │                    │
              │    │            ▼                    │
              │  watch        httpapi ──► thumbcache │
              └──────────────────────────────────────┘
```

| Package | Responsibility |
|---|---|
| `internal/models` | Domain types; the JSON contract. |
| `internal/spiderinfo` | `.ehviewer` parser and formatter (v1 and v2). |
| `internal/scan` | Directory walk, image enumeration, consistency checks. |
| `internal/dbexport` | Read-only exported-DB access and snapshot merging. |
| `internal/index` | Merge filesystem facts with DB metadata; query and facets. |
| `internal/thumbcache` | Bounded, guarded thumbnail rendering and caching. |
| `internal/auth` | Token verification and signed session cookies. |
| `internal/httpapi` | Routes, middleware, DTOs. |
| `internal/watch` | fsnotify with debouncing and a progress ceiling. |
| `internal/config` | Config loading and validation. |
| `internal/builder` | Wires a config to a concrete rebuild. |

The index is built whole and swapped in atomically behind an
`atomic.Pointer`, so readers never take a lock and never observe a partial
build. If a rebuild fails outright, the previous index stays live — Syncthing
can transiently make a directory unreadable, and blanking the library at that
moment would look like data loss.

---

## Security posture

Scoped to "keep the set of people who can reach this library at exactly one".

Implemented:

* Constant-time token comparison and signature verification.
* `HttpOnly; Secure; SameSite=Lax` session cookie, host-only.
* Authentication on every content route, **including images and thumbnails** —
  `/img/<gid>/<index>` is enumerable integers, so an open image endpoint is an
  open content dump.
* Login body capped at 4 KB; malformed and unknown-field bodies rejected.
* Image paths are resolved through the index, never assembled from request
  input, with a containment check against the configured roots as
  belt-and-braces.
* Symlinked gallery directories are skipped by default.
* Decode limits before any image bitmap is allocated.
* A panic in a handler returns 500 rather than killing the process.

Deliberately not implemented: 2FA, multiple users, CSRF tokens, and automatic
IP lockout beyond what the reverse proxy does. There is no state to protect
beyond "can this person read the library", and the cookie is `SameSite=Lax` on
a single origin.

**Rate limiting is not implemented in the Go process.** Put it at the reverse
proxy, where it can also drop unauthenticated requests before they enter the
tunnel. Limiting `/api/v1/auth/login` specifically is the highest-value single
control, because it is the only endpoint an automated attacker can usefully
target.

---

## Development

```sh
go test ./...              # unit and integration tests
go test ./... -count=1     # bypass the result cache
go vet ./...
```

The test suite covers the `.ehviewer` parser against malformed input and both
versions, directory-name and page-number edge cases, the merge rules between
filesystem and DB, the HTTP surface end to end with real PNG bytes, and the
auth flow including tampered and expired sessions.

To generate a synthetic synced tree (including a real SQLite snapshot) for
manual end-to-end checking:

```sh
EHW_FIXTURE_DIR=/tmp/ehw go test ./internal/dbexport -run TestWriteFixtureTree -v
./ehviewer-webd scan -root /tmp/ehw
```

### Corrections worth remembering

Two behaviours of the upstream format are easy to get backwards, and both were
wrong in an earlier draft of the design notes:

1. `SpiderDen.findImageFile` probes `SUPPORT_IMAGE_EXTENSIONS` in declaration
   order (`.jpg`, `.jpeg`, `.png`, `.gif`, `.webp`) and returns the **first**
   hit. When a page exists with several extensions, the earliest **array**
   entry wins — not the alphabetically first, and not the longest match.
2. `SpiderInfo.getStartPage` is a per-character fold, so a non-hex character
   shifts the accumulator rather than terminating the number. `"12-34"` is
   `0x12034`.

Both are pinned by tests (`TestExtensionPrecedence`,
`TestExtensionPrecedenceJpegBeforeJpgAlphabetically`,
`TestStartPageIsAFold`).
