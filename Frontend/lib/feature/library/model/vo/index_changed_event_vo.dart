import 'json_coerce.dart';

/// `index_changed` 事件的负载。
///
/// 由 SSE 层解出来的 JSON 字符串在这里转成强类型对象——SSE 传输层只负责帧
/// 格式，不认识业务事件。
class IndexChangedEventVo {
  const IndexChangedEventVo({
    this.indexAtMs = 0,
    this.snapshotAtMs = 0,
    this.galleries = 0,
    this.added = const [],
    this.changed = const [],
    this.removed = const [],
    this.truncated = false,
    this.reason = '',
  });

  final int indexAtMs;
  final int snapshotAtMs;
  final int galleries;
  final List<int> added;
  final List<int> changed;
  final List<int> removed;

  /// 服务端截断了 id 列表：增量不完整，客户端应当整页重取而不是照着套用。
  final bool truncated;
  final String reason;

  factory IndexChangedEventVo.fromJson(Map<String, dynamic> json) =>
      IndexChangedEventVo(
        indexAtMs: intOr(json['index_at_ms']),
        snapshotAtMs: intOr(json['snapshot_at_ms']),
        galleries: intOr(json['galleries']),
        added: _idList(json['added']),
        changed: _idList(json['changed']),
        removed: _idList(json['removed']),
        truncated: boolOr(json['truncated']),
        reason: stringOr(json['reason']),
      );

  /// 受影响的 gid，供按行刷新的调用方使用。
  Set<int> get affected => {...added, ...changed, ...removed};
}

/// 解析 id 列表：非整数项与 0 一律丢弃，因为 gid 不可能是 0。
List<int> _idList(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .map((e) => e is int ? e : int.tryParse('$e') ?? 0)
      .where((e) => e != 0)
      .toList(growable: false);
}
