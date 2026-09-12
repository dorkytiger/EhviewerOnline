/// 该条目的元数据来自哪里。
enum MetaSource {
  db,
  localOnly,
  orphanDb,
  unknown;

  /// 服务端字符串 → 枚举。未知 / 空值走 [MetaSource.unknown]。
  static MetaSource parse(String? raw) => switch (raw) {
        'db' => MetaSource.db,
        'local_only' => MetaSource.localOnly,
        'orphan_db' => MetaSource.orphanDb,
        _ => MetaSource.unknown,
      };

  /// 展示文案。
  String get label => switch (this) {
        MetaSource.db => '来自数据库快照',
        MetaSource.localOnly => '仅目录信息',
        MetaSource.orphanDb => '数据库有记录但目录缺失',
        MetaSource.unknown => '未知',
      };
}
