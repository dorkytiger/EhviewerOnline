import '../../enum/download_status.dart';
import 'download_page_entry.dart';

/// 一本已下载画廊在磁盘上的清单（`<gid>/manifest.json`）。
///
/// 这是本模块**唯一的事实来源**：列表、占用、能否离线读全部由它推导，不再另存一份
/// 索引（SharedPreferences 里的第二份索引只会和磁盘不同步，然后没人知道该信谁）。
///
/// 页顺序即清单顺序，位置就是寻址方式——与 `PageVo` 的位置语义一致，因为阅读器
/// 也用位置寻址。
class DownloadManifest {
  const DownloadManifest({
    required this.gid,
    required this.title,
    required this.coverPath,
    required this.status,
    required this.downloadedAtMs,
    required this.pages,
  });

  final int gid;

  /// 下载时的标题。存在本地是为了在列表里显示得出来——列表不该为了显示标题去
  /// 请求服务器，那会让「已下载」这个页面在服务器不可达时变成一片空白。
  final String title;

  /// 封面在服务端的相对路径（如 `/thumb/123?v=456`）。
  final String coverPath;

  final DownloadStatus status;

  /// 完成时间；未完成时为写入清单的时间。
  final int downloadedAtMs;

  final List<DownloadPageEntry> pages;

  int get pageCount => pages.length;

  bool get isComplete => status == DownloadStatus.complete;

  /// 第 [position] 页的身份记录；越界时为 null。
  DownloadPageEntry? entryAt(int position) {
    if (position < 0 || position >= pages.length) return null;
    return pages[position];
  }

  /// 只改状态与完成时间的副本，用于下载结束后把清单从 partial 翻成 complete。
  DownloadManifest complete(int atMs) => DownloadManifest(
        gid: gid,
        title: title,
        coverPath: coverPath,
        status: DownloadStatus.complete,
        downloadedAtMs: atMs,
        pages: pages,
      );

  factory DownloadManifest.fromJson(Map<String, dynamic> json) {
    final pages = json['pages'];
    return DownloadManifest(
      gid: switch (json['gid']) {
        final int value => value,
        final String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      title: json['title']?.toString() ?? '',
      coverPath: json['cover_path']?.toString() ?? '',
      status: DownloadStatus.parse(json['status']?.toString()),
      downloadedAtMs: switch (json['downloaded_at_ms']) {
        final int value => value,
        final String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      pages: pages is List
          ? pages
              .whereType<Map<String, dynamic>>()
              .map(DownloadPageEntry.fromJson)
              .toList(growable: false)
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'gid': gid,
        'title': title,
        'cover_path': coverPath,
        'status': status.code,
        'downloaded_at_ms': downloadedAtMs,
        'pages': [for (final page in pages) page.toJson()],
      };
}
