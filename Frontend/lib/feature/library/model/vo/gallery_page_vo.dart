import 'gallery_vo.dart';
import 'json_coerce.dart';

/// 画廊列表的一页。
class GalleryPageVo {
  const GalleryPageVo({
    required this.items,
    required this.nextCursor,
    required this.total,
    required this.limit,
    required this.indexedAtMs,
    required this.snapshotAtMs,
  });

  final List<GalleryVo> items;
  final String nextCursor;
  final int total;

  /// 服务端实际采用的分页大小，可能被服务端上限压小。
  final int limit;

  final int indexedAtMs;

  /// 导出的数据库快照是什么时候生成的。0 表示没有快照。
  ///
  /// UI 会展示它，因为元数据的新鲜度就到这个时间为止；把它当成实时数据是撒谎。
  final int snapshotAtMs;

  factory GalleryPageVo.fromJson(Map<String, dynamic> json) => GalleryPageVo(
        items: mapListOr(json['items'])
            .map(GalleryVo.fromJson)
            .toList(growable: false),
        nextCursor: stringOr(json['next_cursor']),
        total: intOr(json['total']),
        limit: intOr(json['limit']),
        indexedAtMs: intOr(json['indexed_at_ms']),
        snapshotAtMs: intOr(json['snapshot_at_ms']),
      );
}
