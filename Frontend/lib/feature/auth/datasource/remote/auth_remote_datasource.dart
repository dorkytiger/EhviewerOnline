import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/exception/global_exception.dart';
import '../../../../core/service/api_client.dart';
import '../../../../core/service/dio_provider.dart';
import '../../../../core/util/result_util.dart';
import '../../model/request/login_request.dart';
import '../../model/response/authenticated_response.dart';

/// `/api/v1/auth/*` 这个接口域的数据源。
///
/// 只负责收发与解析，不认识会话存在哪：`Set-Cookie` → `SessionStore` 的捕获与
/// 落盘已经在 [ApiClient] 内部完成，这里绝不能再来一遍。存两处就会出现「一处清
/// 了、另一处没清」的幽灵会话——界面显示已登录，请求却一直 401。
class AuthRemoteDatasource {
  const AuthRemoteDatasource(this._client);

  /// 由装配点注入，不在方法体里临时 `ApiClient(...)`：那样会绕开地址与会话的
  /// 唯一装配点，换服务器后新实例连的还是旧地址。
  final ApiClient _client;

  static const String _loginPath = '/api/v1/auth/login';
  static const String _logoutPath = '/api/v1/auth/logout';
  static const String _mePath = '/api/v1/auth/me';

  /// 用访问令牌换取一个会话。
  ///
  /// 令牌是唯一凭据，服务端把它写进 `Set-Cookie`，由 [ApiClient] 负责持久化，
  /// 所以这里只关心成败，不解析响应体。
  Future<Result<void>> login(String token) async {
    final result = await _client.postJson(
      _loginPath,
      body: LoginRequest(token: token).toJson(),
    );
    return _ignoreBody(result);
  }

  /// 通知服务端结束会话。
  ///
  /// 本地会话的清除不在这里做：那是 repository 的职责，否则「远端失败也要清本地」
  /// 这条规则会散落在各层。
  Future<Result<void>> logout() async {
    final result = await _client.postJson(_logoutPath);
    return _ignoreBody(result);
  }

  /// 询问服务端当前会话是否有效。
  Future<Result<bool>> checkSession() async {
    final result = await _client.getJson(_mePath);
    return result.fold<Result<bool>>(_parseAuthenticated, (error) {
      // `/auth/me` 问的就是「当前会话有效吗」，所以 401 是**答案本身**
      // （没有有效会话），不是失败。把它当错误上报，会让全新安装的用户在登录页
      // 看到「登录已过期，请重新登录」——一句从没登录过的人无法理解的话。
      if (error is UnauthorizedException) {
        return Result.success(false);
      }
      return Result.error(error);
    });
  }

  /// 把只关心成败的响应收敛成 `Result<void>`。
  static Result<void> _ignoreBody(Result<Map<String, dynamic>> result) =>
      result.fold<Result<void>>(
        (_) => Result.success(null),
        (error) => Result.error(error),
      );

  /// 解析 `/auth/me` 的响应。
  ///
  /// [AuthenticatedResponse.fromJson] 是模型层唯一的解析入口，它按契约抛
  /// [ParsingException]；在数据边界上就地把它翻译成 `Result`，异常不跨层传播。
  static Result<bool> _parseAuthenticated(Map<String, dynamic> json) {
    try {
      return Result.success(AuthenticatedResponse.fromJson(json).authenticated);
    } on ParsingException catch (error) {
      return Result.error(error);
    }
  }
}

/// [AuthRemoteDatasource] 的装配点。
final authRemoteDatasourceProvider = Provider<AuthRemoteDatasource>(
  (ref) => AuthRemoteDatasource(ref.watch(apiClientProvider)),
);
