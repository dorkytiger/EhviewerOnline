/// 一本画廊在本机的下载状态。
///
/// 只有两种取值，因为**没有第三种可信的说法**：目录里没有清单就是没下载过，
/// 清单写着 partial 就是下到一半，写着 complete 就是下完了。不做「下载中」这类
/// 瞬态取值——那是任务状态（见 `DownloadPhase`），而任务状态活在内存里，重启就
/// 没了，写进磁盘只会留下一堆「下载中」的僵尸记录。
enum DownloadStatus {
  /// 下到一半：有清单和一部分页文件，可以接着下。
  partial('未完成'),

  /// 页齐了，可以离线读。
  complete('已下载');

  const DownloadStatus(this.label);

  /// 面向用户的文案。
  final String label;

  /// 清单里的字符串 → 枚举。
  ///
  /// 未知取值落到 [partial]：把「看不懂的记录」当成未完成是可以恢复的（用户再下
  /// 一次或删掉），当成已完成则会让阅读器去读一堆不存在的页。
  static DownloadStatus parse(String? code) => switch (code) {
        'complete' => DownloadStatus.complete,
        'partial' => DownloadStatus.partial,
        _ => DownloadStatus.partial,
      };

  /// 枚举 → 清单里的字符串。
  String get code => name;
}
