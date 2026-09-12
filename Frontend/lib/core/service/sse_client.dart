/// Server-sent events: wire format, and the pieces of the protocol that matter.
///
/// [EventSource] does not exist outside the browser, so the client parses the
/// stream itself. That means owning the parts of the protocol a browser would
/// normally handle, and each one has a failure mode worth naming:
///
///  * **Multiple `data:` lines belong to one event**, joined with newlines. A
///    parser that takes only the first line silently truncates the payload.
///  * **A blank line terminates an event.** Without it, two events run together
///    and the JSON fails to parse.
///  * **A line starting with `:` is a comment.** The server sends these as
///    keepalives and as a reconnect hint; treating one as data corrupts the
///    frame.
///  * **The `event:` field names the type** and defaults to `message`. The
///    server uses it for `hello` and `index_changed`, so it cannot be ignored.
library;

/// One decoded event from the stream.
class SseEvent {
  const SseEvent({required this.name, required this.data});

  /// The `event:` field, or `message` when absent.
  final String name;

  /// The joined `data:` lines.
  final String data;
}

/// Incremental SSE frame parser.
///
/// Feed it arbitrary chunks; it emits complete events. Written as a stateful
/// parser rather than a `split('\n\n')` because a chunk boundary can fall in
/// the middle of a frame — which happens routinely on a network stream and is
/// invisible until it corrupts exactly one payload in production.
///
/// The model is explicit about one distinction a naive implementation gets
/// wrong: whether the trailing buffered text is a *complete* line (terminated
/// by a newline) or a *partial* one still awaiting more bytes. Only complete
/// lines are parsed during [add]; [flush] handles the partial tail at
/// end-of-stream.
class SseParser {
  final StringBuffer _data = StringBuffer();
  String _event = 'message';

  /// Whether any `data` field was seen for the event being built.
  ///
  /// A separate flag is required rather than testing `_data.isEmpty`: a
  /// `data:` line with an empty value is a legitimate empty payload, and
  /// writing an empty string leaves the buffer empty, so the buffer cannot
  /// distinguish "no data field" from "a data field with no content". Getting
  /// this wrong silently drops every event whose payload is empty.
  bool _sawData = false;

  /// The current line's bytes that have not yet been terminated by a newline.
  String _partial = '';

  /// Adds a chunk and returns whatever complete events it produced.
  List<SseEvent> add(String chunk) {
    if (chunk.isEmpty) return const [];

    final out = <SseEvent>[];
    var start = 0;

    for (var i = 0; i < chunk.length; i++) {
      if (chunk.codeUnitAt(i) != 0x0A) continue; // '\n'

      // A complete line ends here, continuing whatever partial line was
      // buffered from a previous chunk.
      final line = _partial + chunk.substring(start, i);
      _partial = '';
      start = i + 1;

      final event = _consumeLine(line);
      if (event != null) out.add(event);
    }

    // Whatever follows the last newline is a partial line: it may be completed
    // by the next chunk, or be the final line of the stream.
    if (start < chunk.length) {
      _partial += chunk.substring(start);
    }
    return out;
  }

  /// Flushes the partial tail at end-of-stream.
  ///
  /// Only for end-of-stream. Mid-stream a partial line is normal, and flushing
  /// it would emit a bogus event.
  List<SseEvent> flush() {
    final out = <SseEvent>[];

    if (_partial.isNotEmpty) {
      final line = _partial;
      _partial = '';
      // Consuming the final line may itself complete an event (if it was the
      // blank line), or may merely be a data line. Handling both is what makes
      // a stream that ends without a trailing blank line still deliver its last
      // event instead of silently dropping it.
      final event = _consumeLine(line);
      if (event != null) out.add(event);
    }

    // Data accumulated but never dispatched: the stream ended without the blank
    // line that would normally have emitted it.
    if (_sawData) {
      out.add(SseEvent(name: _event, data: _data.toString()));
      _reset();
    }
    return out;
  }

  void _reset() {
    _data.clear();
    _event = 'message';
    _sawData = false;
  }

  /// Consumes one complete line, returning a completed event if it ended one.
  SseEvent? _consumeLine(String line) {
    // Tolerate CRLF: a proxy is allowed to normalise line endings, and a stray
    // \r inside the JSON would break parsing.
    if (line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }

    if (line.isEmpty) {
      // A blank line ends the event. If nothing was accumulated it is padding,
      // not an empty event.
      if (!_sawData && _event == 'message') return null;
      final event = SseEvent(name: _event, data: _data.toString());
      _reset();
      return event;
    }

    if (line.startsWith(':')) {
      // A comment. The server sends these as keepalives and as a reconnect
      // hint; neither carries data.
      return null;
    }

    final colon = line.indexOf(':');
    final String field;
    String value;
    if (colon == -1) {
      // A field with no colon has an empty value. For `data` that is
      // meaningful: it is what produces an event with an empty payload.
      field = line;
      value = '';
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      // Exactly one leading space after the colon is framing, not value.
      if (value.startsWith(' ')) value = value.substring(1);
    }

    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        // Multiple data lines are joined with newlines. The first one must not
        // be preceded by a separator, which is what `_sawData` distinguishes.
        if (_sawData) _data.write('\n');
        _data.write(value);
        _sawData = true;
      case 'id':
      case 'retry':
        // Neither is used by this server. `retry` would set the reconnection
        // delay; the client applies its own backoff, which is preferable
        // because it must also survive a server that is down entirely.
        break;
      default:
        // Unknown fields are ignored, as the specification requires.
        break;
    }
    return null;
  }
}

/// Event names the server sends.
class EventName {
  const EventName._();

  static const hello = 'hello';
  static const indexChanged = 'index_changed';
}
