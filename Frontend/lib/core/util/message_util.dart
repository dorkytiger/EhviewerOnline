import '../exception/global_exception.dart';

/// 从任意错误对象里取出可展示的中文文案。
///
/// 唯一入口：禁止在 UI 各处用 `String(e)` / `e.message` / `JSON.stringify(e)`
/// 自行拼错误文案——那些写法在 `Object` 上根本编译不过，只会得到
/// "Instance of 'FooException'"。
String messageOf(Object? error) {
  if (error is GlobalException) return error.message;
  if (error == null) return '发生未知错误';
  return '发生未知错误';
}
