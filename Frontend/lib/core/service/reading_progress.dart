import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preferences_provider.dart';

/// 某本画廊读到哪一页。
class ReadingProgress {
  const ReadingProgress({required this.page, required this.atMs});

  final int page;

  /// 记录时间，用于将来做「继续阅读」排序。
  final int atMs;
}

/// 每本画廊的阅读进度。
///
/// 刻意只存在本机：后端按设计是只读的，把进度写回同步目录会与 Syncthing
/// 产生冲突（那不是「数据」而是「另一个写入者」）。
///
/// 放 `core` 的理由同 [LocalPrefs]：图库卡片要显示进度、阅读器要读写，
/// 挂在任一 feature 下都会造成 feature 互相依赖 provider。
class ReadingProgressController extends Notifier<Map<int, ReadingProgress>> {
  static const String _prefix = 'progress_';

  @override
  Map<int, ReadingProgress> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final result = <int, ReadingProgress>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final gid = int.tryParse(key.substring(_prefix.length));
      final value = prefs.getString(key);
      if (gid == null || value == null) continue;
      // 存储格式 "page:atMs"；只有 page 是必需的，旧数据可能没有时间戳。
      final parts = value.split(':');
      final page = int.tryParse(parts.first);
      if (page == null) continue;
      result[gid] = ReadingProgress(
        page: page,
        atMs: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
      );
    }
    return result;
  }

  int? pageFor(int gid) => state[gid]?.page;

  Future<void> save(int gid, int page) async {
    final prefs = ref.read(sharedPreferencesProvider);
    final at = DateTime.now().millisecondsSinceEpoch;
    await prefs.setString('$_prefix$gid', '$page:$at');
    state = {...state, gid: ReadingProgress(page: page, atMs: at)};
  }
}

final readingProgressProvider =
    NotifierProvider<ReadingProgressController, Map<int, ReadingProgress>>(
  ReadingProgressController.new,
);
