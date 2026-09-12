import 'dart:convert';

import 'package:ehviewer_online/core/service/sse_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the SSE wire-format parser.
///
/// The client parses the stream itself, because `EventSource` does not exist
/// outside a browser and the session on native platforms is a header rather
/// than a cookie. That means owning the protocol details a browser would
/// normally hide, and each one has a failure mode that only appears under real
/// network conditions.
void main() {
  group('SseParser frames', () {
    test('parses a simple data-only event', () {
      final parser = SseParser();
      final events = parser.add('data: {"a":1}\n\n');

      expect(events, hasLength(1));
      // Without an `event:` field the type defaults to `message`.
      expect(events.single.name, 'message');
      expect(events.single.data, '{"a":1}');
    });

    test('reads the event name', () {
      final parser = SseParser();
      final events = parser.add('event: hello\ndata: {"galleries":1}\n\n');

      expect(events, hasLength(1));
      expect(events.single.name, 'hello');
      expect(events.single.data, '{"galleries":1}');
    });

    // Multiple data lines are one event joined with newlines. A parser that
    // keeps only the first silently truncates the payload — and a parser that
    // emits one event per data line produces invalid JSON.
    test('joins multiple data lines into one event', () {
      final parser = SseParser();
      final events = parser.add('data: {\ndata: "a":1\ndata: }\n\n');

      expect(events, hasLength(1));
      expect(events.single.data, '{\n"a":1\n}');
      // And the joined payload must still be valid JSON.
      expect(jsonDecode(events.single.data), {'a': 1});
    });

    test('ignores comment lines', () {
      final parser = SseParser();
      final events = parser.add(': keepalive\n\n');

      expect(events, isEmpty);

      // A comment between frames must not corrupt the following one.
      final mixed = SseParser().add(': keepalive\ndata: x\n\n');
      expect(mixed, hasLength(1));
      expect(mixed.single.data, 'x');
    });

    test('strips exactly one space after the colon', () {
      // The space is part of the framing, not the value. A value that legitimately
      // begins with a space keeps the rest.
      final parser = SseParser();
      final events = parser.add('data:  two spaces\n\n');
      expect(events.single.data, ' two spaces');
    });

    test('handles a field with no colon', () {
      // "data" alone is a data line with an empty value.
      final parser = SseParser();
      final events = parser.add('data\n\n');
      expect(events, hasLength(1));
      expect(events.single.data, '');
    });

    test('tolerates CRLF line endings', () {
      // A proxy is allowed to normalise line endings, so CRLF must not leave a
      // stray \r inside the JSON.
      final parser = SseParser();
      final events = parser.add('event: hello\r\ndata: {"a":1}\r\n\r\n');

      expect(events, hasLength(1));
      expect(events.single.name, 'hello');
      expect(events.single.data, '{"a":1}');
    });

    test('ignores unknown fields and id/retry', () {
      final parser = SseParser();
      final events = parser.add('id: 42\nretry: 1000\nfoo: bar\ndata: x\n\n');
      expect(events, hasLength(1));
      expect(events.single.data, 'x');
    });

    test('emits several events from one chunk', () {
      final parser = SseParser();
      final events = parser.add('event: hello\ndata: a\n\ndata: b\n\n');
      expect(events, hasLength(2));
      expect(events[0].name, 'hello');
      expect(events[1].name, 'message');
      expect(events[1].data, 'b');
    });

    test('a blank line with no data is not an event', () {
      final parser = SseParser();
      expect(parser.add('\n\n\n'), isEmpty);
    });
  });

  group('SseParser chunk boundaries', () {
    // The case that makes a naive split('\n\n') implementation fail: a chunk
    // boundary landing mid-frame. On a real socket this happens routinely and
    // corrupts exactly one payload, which is the worst kind of bug to find in
    // production.
    test('reassembles a frame split across chunks', () {
      final parser = SseParser();

      expect(parser.add('event: ind'), isEmpty);
      expect(parser.add('ex_changed\nda'), isEmpty);
      expect(parser.add('ta: {"gid'), isEmpty);

      final events = parser.add('s":7}\n\n');
      expect(events, hasLength(1));
      expect(events.single.name, 'index_changed');
      expect(events.single.data, '{"gids":7}');
    });

    test('reassembles a frame split at the blank line', () {
      final parser = SseParser();
      expect(parser.add('data: x\n'), isEmpty);
      // The terminating newline arrives alone.
      final events = parser.add('\n');
      expect(events, hasLength(1));
      expect(events.single.data, 'x');
    });

    test('handles a chunk per character', () {
      final parser = SseParser();
      const frame = 'event: hello\ndata: {"galleries":1}\n\n';
      final collected = <SseEvent>[];
      for (final rune in frame.split('')) {
        collected.addAll(parser.add(rune));
      }
      expect(collected, hasLength(1));
      expect(collected.single.name, 'hello');
      expect(collected.single.data, '{"galleries":1}');
    });

    test('handles two frames arriving in one chunk with a partial third', () {
      final parser = SseParser();
      final events = parser.add('data: a\n\ndata: b\n\ndata: par');
      expect(events, hasLength(2));
      expect(events[0].data, 'a');
      expect(events[1].data, 'b');

      // The partial frame completes later.
      final rest = parser.add('tial\n\n');
      expect(rest, hasLength(1));
      expect(rest.single.data, 'partial');
    });
  });

  group('SseParser flush', () {
    // flush is only for end-of-stream. Mid-stream a partial line is normal and
    // flushing it would emit a bogus event.
    test('flush releases a buffered partial line', () {
      final parser = SseParser();
      expect(parser.add('data: last'), isEmpty);

      final events = parser.flush();
      expect(events, hasLength(1));
      expect(events.single.data, 'last');
    });

    test('flush is a no-op on an empty buffer', () {
      final parser = SseParser();
      expect(parser.flush(), isEmpty);
    });
  });
}
