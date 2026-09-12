import '../../enum/gallery_anomaly.dart';

// --- 类型宽松处理 -----------------------------------------------------------
//
// 服务端对类型很严格，但「遇到意外的 JSON 类型就抛异常」的客户端，会在服务端
// 加字段或代理改写数字时直接坏掉。这里统一做兼容转换，并且**只在这里做一次**，
// 各 VO 的 `fromJson` 直接复用。

/// 转成 `String`，null 变空串。
String stringOr(Object? value) => value == null ? '' : value.toString();

/// 转成可空 `String`：null 保持 null，其余转字符串。
///
/// 用于枚举字段——`''` 和「字段缺失」都要落到 `unknown`，但不能把 `''` 当成
/// 一个有意义的取值。
String? stringOrNull(Object? value) => value?.toString();

/// 转成 `int`，无法解析时返回 0。
int intOr(Object? value) {
  switch (value) {
    case int i:
      return i;
    case double d:
      return d.toInt();
    case String s:
      return int.tryParse(s) ?? 0;
    default:
      return 0;
  }
}

/// 转成 `double`，无法解析时返回 0。
double doubleOr(Object? value) {
  switch (value) {
    case double d:
      return d;
    case int i:
      return i.toDouble();
    case String s:
      return double.tryParse(s) ?? 0;
    default:
      return 0;
  }
}

/// 转成 `bool`；只有服务端明确发 `true` 才算真。
bool boolOr(Object? value) => value == true;

/// 转成字符串列表；不是列表时返回空表。
List<String> stringListOr(Object? value) {
  if (value is! List) return const [];
  return value.map((e) => e.toString()).toList(growable: false);
}

/// 转成异常码列表；不是列表时返回空表。
List<GalleryAnomaly> anomaliesOr(Object? value) {
  if (value is! List) return const [];
  return value.map((e) => GalleryAnomaly(e.toString())).toList(growable: false);
}

/// 从响应里取一个对象字段；类型不符时返回空对象。
Map<String, dynamic> mapOr(Object? value) =>
    value is Map<String, dynamic> ? value : const {};

/// 提取响应里的对象列表，跳过类型不符的元素。
List<Map<String, dynamic>> mapListOr(Object? value) {
  if (value is! List) return const [];
  return value.whereType<Map<String, dynamic>>().toList(growable: false);
}
