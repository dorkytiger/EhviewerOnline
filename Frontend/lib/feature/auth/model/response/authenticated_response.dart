import '../../../../core/exception/global_exception.dart';

/// `GET /api/v1/auth/me` 的响应体。
///
/// [fromJson] 是这条响应唯一的解析入口，别处不得再 `json['authenticated']` 裸取。
///
/// 这条响应的解析策略是**严格**的：字段缺失或类型不对一律抛 [ParsingException]。
/// 与列表类模型「元数据字段容错」的策略相反，因为 `authenticated` 没有安全的
/// 默认值——把缺失当成 `false`，会把「后端接口改坏了」伪装成「用户没登录」，
/// 让人在完全错误的方向上排查（怀疑令牌、怀疑会话，而问题在契约）。
class AuthenticatedResponse {
  const AuthenticatedResponse({required this.authenticated});

  /// 服务端对「当前会话是否有效」的回答。
  final bool authenticated;

  /// 解析响应。
  ///
  /// 抛出的 [ParsingException] 必须点名字段：排查的人要能一眼看出是契约对不上，
  /// 而不是网络问题。
  factory AuthenticatedResponse.fromJson(Map<String, dynamic> json) {
    final value = json['authenticated'];
    if (value is bool) {
      return AuthenticatedResponse(authenticated: value);
    }
    throw ParsingException(
      message: value == null
          ? 'auth/me 响应缺少 authenticated 字段'
          : 'auth/me 响应的 authenticated 不是布尔值（${value.runtimeType}）',
    );
  }
}
