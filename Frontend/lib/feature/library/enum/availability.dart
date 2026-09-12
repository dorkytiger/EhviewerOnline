/// 画廊在服务端磁盘上的可用程度。
///
/// 服务端返回枚举字符串，解析**只在这里做一次**：未知取值一律落到
/// [Availability.unknown]，绝不静默当成 [Availability.ok]——把「不知道」显示
/// 成「可读」比显示成「未知」危险得多。
enum Availability {
  ok,
  degraded,
  missing,
  unknown;

  /// 服务端字符串 → 枚举。未知 / 空值走 [Availability.unknown]。
  static Availability parse(String? raw) => switch (raw) {
        'ok' => Availability.ok,
        'degraded' => Availability.degraded,
        'missing' => Availability.missing,
        _ => Availability.unknown,
      };

  /// 展示文案。
  String get label => switch (this) {
        Availability.ok => '可读',
        Availability.degraded => '异常',
        Availability.missing => '未同步',
        Availability.unknown => '未知',
      };
}
