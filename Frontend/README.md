# ehviewer-online (Flutter client)

A cross-platform client for [ehviewer-webd](../Backend), the read-only HTTP
service that serves a Syncthing-synced EhViewer library.

## Platforms

Generated and buildable for all of them:

| Platform | Status | Notes |
|---|---|---|
| Android | ✅ | The primary target; closest to the original app's feel. |
| iOS | ✅ | Project generated; needs a Mac to build. |
| Web | ✅ | Any browser, no install. The reason the backend is reachable from a TV or a borrowed laptop. |
| Windows | ✅ | Verified: `flutter build windows` produces a working binary. |
| Linux | ✅ | Project generated; built on the deployment host or in CI. |
| macOS | — | Not generated. Add it with `flutter create --platforms=macos .` if you want it. |

```sh
flutter run -d chrome   --dart-define=EHW_BASE_URL=https://your.host
flutter run -d windows  --dart-define=EHW_BASE_URL=https://your.host
flutter build apk       --dart-define=EHW_BASE_URL=https://your.host
flutter build web       --dart-define=EHW_BASE_URL=https://your.host
flutter build windows   --dart-define=EHW_BASE_URL=https://your.host
```

### The base URL is a build-time constant

`EHW_BASE_URL` is a `String.fromEnvironment`, so it is compiled in. It defaults
to `http://127.0.0.1:8080`, which is deliberately useless for a real deployment:
a forgotten `--dart-define` fails visibly rather than pointing at somebody
else's server.

For a single build that serves several hostnames, change `AppConfig.baseUrl` to
read from a settings field instead.

## Architecture

```
lib/
  core/config.dart          compile-time configuration
  data/
    models.dart             JSON contract, hand-written fromJson
    api_client.dart         Dio client, session handling, error mapping
  providers/
    app_providers.dart      Riverpod: auth, filter, list, detail, local prefs
  ui/
    app_shell.dart          bottom navigation
    router.dart             go_router with an auth redirect
    format.dart             display formatters
    pages/                  login, library, detail, reader, settings
    widgets/                gallery card, server image, filter sheet
```

### State

Riverpod 3, no code generation. The list is an `AsyncNotifier` whose `build`
watches the filter provider, so changing a filter re-runs the query from page
one — appending page two of the old query to page one of the new one would
produce a silently wrong list. Paging appends through `loadMore`, guarded
against concurrent calls because a fast scroll fires it many times per frame.

### Session handling, and why images go through Dio

On web the session lives in an `HttpOnly` cookie the browser manages, so the
client sends credentials and never reads the cookie. Native platforms have no
cookie jar, so the value is captured from the login response's `Set-Cookie` and
replayed as a `Cookie` header by an interceptor.

That same interceptor is why `ServerImage` fetches through Dio rather than using
`Image.network`: the latter cannot carry an Authorization header, and on native
the cookie is not automatic.

### Two theming systems

`forui` 0.26 supplies its own `material_ui` / `cupertino_ui` packages and does
not depend on `flutter/material`. The app therefore runs both:

* `FTheme` from forui provides `FScaffold`, `FButton`, `FCard`, `FHeader` and
  the rest of the F-prefixed widget set;
* `MaterialApp` / `ThemeData` provides the widgets forui does not cover —
  `NavigationBar`, `Slider`, `RadioListTile`, modal sheets, `RefreshIndicator`.

`FTheme` is installed inside `MaterialApp.builder` so it sits above the
navigator and every route can resolve it.

## What the UI says that a naive client would hide

The backend is honest about what it does not know, and the UI has to be too,
because every count in it is only as accurate as the data behind it:

* **The metadata snapshot is not live.** Metadata comes from a database the
  user exported on the phone, so it lags. The status bar at the bottom of the
  library and the whole of the settings page report when the snapshot was taken
  and when the filesystem was last indexed, rather than implying "now".
* **`features.tags = false` hides the tag filter.** The exported snapshot has
  no `Gallery_Tags` table, so tag filtering is impossible. The filter sheet says
  so instead of offering a control that never matches.
* **Category names are guesses.** The integer comes from a class in an AAR
  dependency that could not be verified from source, so the raw number is shown
  next to the name.
* **`title_source: dirname` is flagged.** The title is then the sanitized
  directory name, not the real one, and the detail page says so.
* **Anomalies are explained by consequence.** A page-count mismatch becomes
  "缺 3 页" with a note that reading will skip them, not a raw
  `page_count_mismatch`.
* **A missing directory is not an error.** A DB row with no folder (Syncthing
  has not caught up) appears dimmed and marked 未同步 rather than vanishing,
  which would look like data loss.

## Reader

Three things it has to get right:

1. **Memory.** A 300-page gallery cannot be held in memory. `PageView` keeps
   only the current page and its neighbours; vertical mode uses a `ListView`
   with a viewport-relative `ScrollCacheExtent`. `AppConfig.readerPreloadRadius`
   bounds how far ahead it builds.
2. **Missing pages.** Page numbers can have gaps, so pages are addressed by
   their position in the list, never by assuming index equals position. The
   image URL uses the page's own index, and a gap shows an explicit banner.
3. **Progress.** Saved locally on every page change. Nothing is written back to
   the server: the backend is read-only by design, and writing into the synced
   tree would fight with Syncthing.

## Development

```sh
flutter pub get
flutter analyze                 # must be clean
flutter test                    # contract tests, see below
flutter run -d windows --dart-define=EHW_BASE_URL=http://127.0.0.1:8080
```

### Tests

`test/api_client_test.dart` runs against a real in-process HTTP server rather
than a mocked Dio, so the whole transport stack is covered: JSON encoding,
status handling, cookie capture and replay, query-parameter construction, and
error mapping. The fixtures are copied from real `ehviewer-webd` responses.

That matters because it catches the failure mode a mock hides: a server contract
change that this client has not been updated for. It also pins the tolerant
parsing rules — an unknown anomaly code shows itself rather than disappearing,
an unknown availability lands in an explicit `unknown` bucket, a numeric field
sent as a string is coerced, and missing optional fields degrade instead of
throwing.

## Live updates

`lib/data/sse.dart` implements the wire format and `LiveUpdatesNotifier` in
`app_providers.dart` consumes it.

`EventSource` does not exist outside a browser, so the client parses the stream
itself. That means owning the protocol details a browser would normally hide,
and each one has a failure mode that only appears under real network conditions:

* **Multiple `data:` lines are one event**, joined with newlines. A parser that
  keeps only the first silently truncates the payload.
* **A blank line terminates an event.** Without it, two events run together.
* **A line starting with `:` is a comment.** The server sends these as
  keepalives; treating one as data corrupts the frame.
* **A chunk boundary can fall anywhere**, including mid-frame and mid-character.
  A naive `split('\n\n')` works until it corrupts exactly one payload in
  production. The parser is byte-oriented and stateful for this reason.
* **An empty `data:` line is a real, empty payload.** The parser tracks whether
  it saw a data field at all rather than testing whether its buffer is empty,
  because a buffer cannot distinguish the two — and getting that wrong drops
  every event with an empty payload.

The stream reconnects on its own with capped exponential backoff. That matters
because the server closes it every 30 minutes by design and a flaky tunnel drops
it more often; a client that gave up on the first disconnect would stop
receiving updates for the rest of the session.

### A live change does not reset your place

`GalleryListController.applyLiveChange` refetches only the first page and
mirrors it onto the rows already held, rather than calling `refresh`. A plain
refresh would drop every page the user has scrolled through back to page one,
which is a worse outcome than the update is good: they did not ask for it.

The trade is explicit: a new gallery sorts by download time and the default sort
is newest-first, so it usually lands on page one and appears immediately.
Anything the active sort would place far down the list is picked up on the next
manual refresh instead of causing a scroll jump.

### The one proxy setting that will silently break it

A reverse proxy that buffers responses accepts the SSE connection, returns
`200`, and then holds the stream. The client shows a live connection that never
produces an event, with no error anywhere. Nginx needs `proxy_buffering off;`
and Caddy needs `flush_interval -1`.

The server writes a `hello` event immediately and flushes, so the client can
tell "connected and quiet" from "connected but buffered" by whether that first
event arrived. The status bar shows a bolt icon: filled when live, outlined when
the server reports no event hub, with a tooltip explaining that updates need a
manual refresh.

## Not implemented

* **Pull to refresh on web** — `RefreshIndicator` needs a touch gesture; the
  library screen has a refresh button in the header for mouse and keyboard.
* **Per-gallery resume across devices.** Progress is local to the device by
  design.
* **Offline mode.** Nothing is cached for reading without the server; only
  covers and pages the HTTP layer already fetched are reused.
* **A live-update feed in the reader.** A gallery being re-synced underneath an
  open reader refetches its detail, but the reader does not reposition or
  re-warn mid-read.

