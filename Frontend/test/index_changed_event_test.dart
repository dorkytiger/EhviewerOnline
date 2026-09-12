import 'package:ehviewer_online/feature/library/model/vo/index_changed_event_vo.dart';
import 'package:flutter_test/flutter_test.dart';

/// `index_changed` 事件负载的解析测试。
///
/// 这些用例原来住在 SSE 传输层的测试里，但负载模型已经从传输层搬到了 library
/// 的 VO —— 传输层只该认识帧格式，不该认识业务事件。测试跟着模型走。
void main() {
  group('IndexChangedEventVo', () {
    test('parses a full payload', () {
      final event = IndexChangedEventVo.fromJson({
        'index_at_ms': 1700000000000,
        'snapshot_at_ms': 1699999000000,
        'galleries': 7,
        'added': [1, 2],
        'changed': [3],
        'removed': [4],
        'truncated': false,
        'reason': 'filesystem_change',
      });

      expect(event.indexAtMs, 1700000000000);
      expect(event.snapshotAtMs, 1699999000000);
      expect(event.galleries, 7);
      expect(event.added, [1, 2]);
      expect(event.changed, [3]);
      expect(event.removed, [4]);
      expect(event.truncated, isFalse);
      expect(event.reason, 'filesystem_change');
      expect(event.affected, {1, 2, 3, 4});
    });

    test('missing fields degrade to zero rather than throwing', () {
      final event = IndexChangedEventVo.fromJson(const {});
      expect(event.galleries, 0);
      expect(event.added, isEmpty);
      expect(event.affected, isEmpty);
      expect(event.truncated, isFalse);
    });

    // The server caps its id lists and sets truncated, which means the delta is
    // incomplete. A client that applied it anyway would leave stale rows on
    // screen with no way to know.
    test('records truncation', () {
      final event = IndexChangedEventVo.fromJson({
        'galleries': 5000,
        'truncated': true,
        'added': [1],
      });
      expect(event.truncated, isTrue);
    });

    test('coerces ids sent as strings', () {
      final event = IndexChangedEventVo.fromJson({
        'added': ['123', 456],
      });
      expect(event.added, [123, 456]);
    });

    test('ignores unusable ids', () {
      final event = IndexChangedEventVo.fromJson({
        'added': ['not-a-number', null, 7],
      });
      // 0 is the sentinel for "unparseable" and is filtered out.
      expect(event.added, [7]);
    });

    test('a non-list id field is treated as empty', () {
      final event = IndexChangedEventVo.fromJson({'added': 'oops'});
      expect(event.added, isEmpty);
    });
  });
}
