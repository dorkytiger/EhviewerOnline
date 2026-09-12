import '../vo/gallery_vo.dart';

/// 累积的画廊列表状态，让翻页是追加而不是替换。
class LibraryListState {
  const LibraryListState({
    this.galleries = const [],
    this.total = 0,
    this.nextCursor = '',
    this.loadingMore = false,
    this.loadMoreError,
    this.indexedAtMs = 0,
    this.snapshotAtMs = 0,
  });

  final List<GalleryVo> galleries;
  final int total;
  final String nextCursor;
  final bool loadingMore;

  /// 追加加载的失败信息，和已经加载出来的画廊并存。
  ///
  /// 放在这里而不是用 `AsyncError` 承载：第三页失败就把已经加载的列表全丢掉，
  /// 对用户是敌意行为。
  final String? loadMoreError;

  final int indexedAtMs;
  final int snapshotAtMs;

  bool get hasMore => nextCursor.isNotEmpty;

  LibraryListState copyWith({
    List<GalleryVo>? galleries,
    int? total,
    String? nextCursor,
    bool? loadingMore,
    String? loadMoreError,
    bool clearLoadMoreError = false,
    int? indexedAtMs,
    int? snapshotAtMs,
  }) {
    return LibraryListState(
      galleries: galleries ?? this.galleries,
      total: total ?? this.total,
      nextCursor: nextCursor ?? this.nextCursor,
      loadingMore: loadingMore ?? this.loadingMore,
      loadMoreError:
          clearLoadMoreError ? null : (loadMoreError ?? this.loadMoreError),
      indexedAtMs: indexedAtMs ?? this.indexedAtMs,
      snapshotAtMs: snapshotAtMs ?? this.snapshotAtMs,
    );
  }
}
