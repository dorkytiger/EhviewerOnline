import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/exception/global_exception.dart';
import '../../../core/util/result_util.dart';
import '../repository/auth_repository.dart';

/// 认证用例。
///
/// 这是本模块**对外**的边界：其他模块（设置页换服务器时会清会话）只允许依赖
/// 这里的 [forgetSession]，不得直接碰 repository 或 datasource。下面这几个方法
/// 名与签名已经被外部依赖，改名要同步改调用方。
class AuthService {
  const AuthService(this._repository);

  final AuthRepository _repository;

  /// 空令牌的统一提示文案。
  ///
  /// 控制器为了「不发无用的请求」要在本地先拦一次空令牌，用的必须是同一句文案。
  /// 文案只定义在这里，避免本地校验与服务层校验各说各话。
  static const String emptyTokenMessage = '令牌不能为空';

  /// 用访问令牌登录。
  ///
  /// 空令牌在这里就地拒绝，不产生任何网络请求：它不可能是有效凭据，跑一趟只会
  /// 让用户白等一个 RTT；而设置模块若直接调用本方法，也能得到同样的保护。
  Future<Result<void>> login(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      return Result.error(
        const ValidationException(message: emptyTokenMessage),
      );
    }
    return _repository.login(trimmed);
  }

  /// 询问服务端当前会话是否有效。
  Future<Result<bool>> checkSession() => _repository.checkSession();

  /// 退出登录。
  ///
  /// 远端失败也会清掉本地会话，理由见 [AuthRepository.logout]。
  Future<Result<void>> logout() => _repository.logout();

  /// 只清本地会话，不通知服务端（换服务器时用）。
  Future<void> forgetSession() => _repository.forgetSession();
}

/// [AuthService] 的装配点。
final authServiceProvider = Provider<AuthService>(
  (ref) => AuthService(ref.watch(authRepositoryProvider)),
);
