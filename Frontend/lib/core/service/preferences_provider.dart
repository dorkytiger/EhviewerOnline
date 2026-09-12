import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动时加载好的 [SharedPreferences] 实例，在 `main` 里覆盖。
///
/// 覆盖之前读取它是编程错误：直接抛异常比悄悄构造第二个空存储要好——
/// 后者会让「设置保存了但重启就没了」变成一个极难查的问题。
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in ProviderScope',
  );
});
