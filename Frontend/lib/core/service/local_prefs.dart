import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

import '../exception/global_exception.dart';
import '../util/result_util.dart';
import 'preferences_provider.dart';

/// 阅读时滑动翻页的方向。
enum ReaderDirection {
  leftToRight('从左到右', '下一页在右侧'),
  rightToLeft('从右到左', '下一页在左侧（日式）'),
  vertical('纵向滚动', '连续滚动');

  const ReaderDirection(this.label, this.description);

  final String label;
  final String description;

  static ReaderDirection parse(String? raw) =>
      ReaderDirection.values.where((d) => d.name == raw).firstOrNull ??
      ReaderDirection.leftToRight;
}

/// 页面如何缩放到视口。
enum ReaderFit {
  contain('适应屏幕', '完整显示整页'),
  width('适应宽度', '按宽度铺满，可上下滚动'),
  original('原始尺寸', '不做缩放');

  const ReaderFit(this.label, this.description);

  final String label;
  final String description;

  static ReaderFit parse(String? raw) =>
      ReaderFit.values.where((f) => f.name == raw).firstOrNull ?? ReaderFit.contain;
}

/// 只存在本机的界面偏好。
class LocalPrefs {
  const LocalPrefs({
    required this.themeMode,
    required this.readerDirection,
    required this.fitMode,
  });

  final ThemeMode themeMode;
  final ReaderDirection readerDirection;
  final ReaderFit fitMode;

  LocalPrefs copyWith({
    ThemeMode? themeMode,
    ReaderDirection? readerDirection,
    ReaderFit? fitMode,
  }) {
    return LocalPrefs(
      themeMode: themeMode ?? this.themeMode,
      readerDirection: readerDirection ?? this.readerDirection,
      fitMode: fitMode ?? this.fitMode,
    );
  }
}

/// 界面偏好状态。
///
/// 放在 `core` 而不是某个 feature 里，是因为它有三个互不相关的消费者：
/// `main.dart` 读主题、图库列表读阅读方向（用于卡片上的进度条方向）、阅读器
/// 读全部三项。挂在任一 feature 下都会逼出「feature 之间互相 import
/// provider」，而规范只允许跨模块依赖 service。
///
/// 持久化是纯键值读写，没有业务规则，所以直接放这里；设置页只是这些值的
/// 一个编辑器。
class LocalPrefsController extends Notifier<LocalPrefs> {
  static const String _themeKey = 'pref_theme_mode';
  static const String _directionKey = 'pref_reader_direction';
  static const String _fitKey = 'pref_reader_fit';

  @override
  LocalPrefs build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return LocalPrefs(
      themeMode: _parseTheme(prefs.getString(_themeKey)),
      readerDirection: ReaderDirection.parse(prefs.getString(_directionKey)),
      fitMode: ReaderFit.parse(prefs.getString(_fitKey)),
    );
  }

  static ThemeMode _parseTheme(String? raw) => switch (raw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  /// 写入一项偏好。
  ///
  /// 返回 `Result` 而不是 `void`：写偏好真的会失败（磁盘满、平台通道异常），
  /// 而「点了却没生效、也没有任何提示」是用户唯一无法自行诊断的失败——他们
  /// 只会以为应用坏了。失败时状态**不变**，界面因此仍与存储一致。
  Future<Result<void>> _write(String key, String value) async {
    final ok = await ref.read(sharedPreferencesProvider).setString(key, value);
    if (!ok) {
      return Result.error(const LocalStorageException(message: '偏好保存失败'));
    }
    return Result.success(null);
  }

  Future<Result<void>> setThemeMode(ThemeMode mode) async {
    final result = await _write(_themeKey, mode.name);
    if (result.isError) return result;
    state = state.copyWith(themeMode: mode);
    return Result.success(null);
  }

  Future<Result<void>> setReaderDirection(ReaderDirection direction) async {
    final result = await _write(_directionKey, direction.name);
    if (result.isError) return result;
    state = state.copyWith(readerDirection: direction);
    return Result.success(null);
  }

  Future<Result<void>> setFitMode(ReaderFit fit) async {
    final result = await _write(_fitKey, fit.name);
    if (result.isError) return result;
    state = state.copyWith(fitMode: fit);
    return Result.success(null);
  }
}

final localPrefsProvider =
    NotifierProvider<LocalPrefsController, LocalPrefs>(LocalPrefsController.new);
