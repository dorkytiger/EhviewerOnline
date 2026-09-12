/// 展示标题的来源。
///
/// [dirname] 表示标题是从目录名清洗出来的，不是真实标题；UI 需要据此标注，
/// 否则用户会以为看到的是元数据里的原始标题。
enum TitleSource {
  db,
  dirname,
  unknown;

  /// 服务端字符串 → 枚举。未知 / 空值走 [TitleSource.unknown]。
  static TitleSource parse(String? raw) => switch (raw) {
        'db' => TitleSource.db,
        'dirname' => TitleSource.dirname,
        _ => TitleSource.unknown,
      };
}
