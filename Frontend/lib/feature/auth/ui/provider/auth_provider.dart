import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/util/message_util.dart';
import '../../model/state/auth_state.dart';
import '../../service/auth_service.dart';

/// 认证状态的 viewmodel。
///
/// 只承载 UI 状态与展示逻辑：会话校验、登录、退出的实际动作都在 [AuthService]，
/// 这里负责把 `Result` 映射成三态，并保证 `build` 同步返回。
class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    // build 必须同步返回，所以校验不能 await：先给出 checking，再让微任务去问
    // 服务端。初始态若是 unauthenticated，路由会先渲染登录页再跳走——已登录的
    // 用户每次冷启动都会看到一次登录页闪现。
    Future.microtask(refresh);
    return const AuthState.checking();
  }

  AuthService get _service => ref.read(authServiceProvider);

  /// 重新向服务端确认会话。
  ///
  /// 不把状态退回 checking：这是显式刷新，路由不该再把已渲染的界面换成占位页。
  Future<void> refresh() async {
    final result = await _service.checkSession();
    if (!ref.mounted) return;
    state = result.fold<AuthState>(
      (authenticated) => authenticated
          ? const AuthState(status: AuthStatus.authenticated)
          : const AuthState.unauthenticated(),
      // 「校验失败」与「服务端说未登录」是两件事：前者要说明原因，否则用户莫名
      // 停在登录页而没有任何解释（比如服务器根本没起来）。
      (error) => AuthState.unauthenticated(error: messageOf(error)),
    );
  }

  /// 提交令牌。
  ///
  /// 返回是否成功；失败原因同时写进 [AuthState.error]，这样声明式（watch 状态）
  /// 与命令式（看返回值）两种调用方都能用。
  Future<bool> login(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      // 本地拦截：空令牌不可能通过服务端校验，发出去只是白等一个 RTT，而且会
      // 得到一句与服务端状态无关的「令牌无效」，误导用户去怀疑令牌本身。
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        error: AuthService.emptyTokenMessage,
        submitting: false,
      );
      return false;
    }

    state = state.copyWith(submitting: true, clearError: true);
    final result = await _service.login(trimmed);
    if (!ref.mounted) return result.isSuccess;

    return result.fold<bool>(
      (_) {
        state = const AuthState(status: AuthStatus.authenticated);
        return true;
      },
      (error) {
        state = AuthState.unauthenticated(error: messageOf(error));
        return false;
      },
    );
  }

  /// 退出登录。
  ///
  /// 本地会话一定被清掉（见 [AuthService.logout]），所以状态无条件回到未登录；
  /// 远端没确认成功时把原因留在 [AuthState.error] 里，说明「本地已退出、服务端
  /// 没应答」，而不是吞掉那次失败让用户以为一切正常。
  Future<void> logout() async {
    final result = await _service.logout();
    if (!ref.mounted) return;
    state = result.isSuccess
        ? const AuthState(status: AuthStatus.unauthenticated)
        : AuthState.unauthenticated(
            error: '已在本地退出，但服务器未确认：${messageOf(result.error)}',
          );
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
