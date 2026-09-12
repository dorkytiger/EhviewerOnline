import 'json_coerce.dart';

/// `/api/v1/meta` 返回的索引统计与功能开关。
class ServerMetaVo {
  const ServerMetaVo({
    required this.version,
    required this.serverTimeMs,
    required this.galleries,
    required this.onDisk,
    required this.missing,
    required this.degraded,
    required this.pages,
    required this.totalBytes,
    required this.skippedDirs,
    required this.snapshotAtMs,
    required this.snapshotFile,
    required this.indexedAtMs,
    required this.warnings,
    required this.supportsTags,
    required this.supportsThumbnails,
    required this.supportsSse,
  });

  final String version;
  final int serverTimeMs;
  final int galleries;
  final int onDisk;
  final int missing;
  final int degraded;
  final int pages;
  final int totalBytes;
  final int skippedDirs;
  final int snapshotAtMs;
  final String snapshotFile;
  final int indexedAtMs;
  final List<String> warnings;

  /// 服务端是否支持按标签过滤。
  ///
  /// 对着数据库快照时**恒为 false**，因为导出文件里没有 Gallery_Tags 表。UI
  /// 据此隐藏标签筛选，而不是给出一个永远匹配不到任何东西的控件。
  final bool supportsTags;
  final bool supportsThumbnails;
  final bool supportsSse;

  factory ServerMetaVo.fromJson(Map<String, dynamic> json) {
    final index = mapOr(json['index']);
    final features = mapOr(json['features']);
    return ServerMetaVo(
      version: stringOr(json['version']),
      serverTimeMs: intOr(json['server_time_ms']),
      galleries: intOr(index['galleries']),
      onDisk: intOr(index['on_disk']),
      missing: intOr(index['missing']),
      degraded: intOr(index['degraded']),
      pages: intOr(index['pages']),
      totalBytes: intOr(index['total_bytes']),
      skippedDirs: intOr(index['skipped_dirs']),
      snapshotAtMs: intOr(index['snapshot_at_ms']),
      snapshotFile: stringOr(json['snapshot_file']),
      indexedAtMs: intOr(index['indexed_at_ms']),
      warnings: stringListOr(json['warnings']),
      supportsTags: boolOr(features['tags']),
      supportsThumbnails: boolOr(features['thumbnails']),
      supportsSse: boolOr(features['sse']),
    );
  }
}
