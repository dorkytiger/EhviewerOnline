/// 登录请求体。
///
/// 与后端字段一一对应，是这条出站 JSON 的唯一来源：datasource 不得再手拼 `Map`
/// 字面量，否则字段一旦改名就只能靠全局搜索去找散落各处的裸取点。
class LoginRequest {
  const LoginRequest({required this.token});

  /// 访问令牌，本次请求唯一的凭据。
  final String token;

  Map<String, dynamic> toJson() => <String, dynamic>{'token': token};
}
