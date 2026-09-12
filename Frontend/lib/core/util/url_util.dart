/// 服务器地址的归一化与校验。
///
/// 放在 `core/util` 而不是某一边：客户端和设置页必须用**同一套**规则。
/// 「http://host:8080/」和「http://host:8080」是同一台服务器，只差一个斜杠就被
/// 当成换服务器会白白掉一次会话；而 `ApiClient` 如果不自己归一化，它就只有
/// 「装配点恰好归一化了」这一个保证——直接 new 出来的实例会踩。
library;

import '../exception/global_exception.dart';

/// 去掉首尾空白与末尾斜杠。
String normalizeBaseUrl(String raw) {
  var value = raw.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// 校验地址形态，返回 null 表示合法。
GlobalException? validateBaseUrl(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      !uri.hasScheme ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return const ValidationException(message: '地址需要形如 http://主机:端口');
  }
  return null;
}
