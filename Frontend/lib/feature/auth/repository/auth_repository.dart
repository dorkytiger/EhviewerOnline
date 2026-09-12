import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/service/session_store.dart';
import '../../../core/util/result_util.dart';
import '../datasource/remote/auth_remote_datasource.dart';

/// 会话这一数据边界上的编排。
///
/// 存在的理由是把**本地会话**与**远端会话**绑在一起处理：它俩必须同步，任何只
/// 动其中一边的路径都会留下一个「界面显示已登录、请求却全 401」的幽灵会话。因此
/// 所有会改变会话的操作都必须经过这里。
class AuthRepository {
  const AuthRepository(this._remote, this._session);

  final AuthRemoteDatasource _remote;
  final SessionStore _session;

  /// 换取会话。
  ///
  /// 成功后会话值已由 [ApiClient] 落盘（它才是唯一知道 `Set-Cookie` 的地方），
  /// 所以这里不做额外持久化。
  Future<Result<void>> login(String token) => _remote.login(token);

  /// 校验会话是否仍然有效。
  Future<Result<bool>> checkSession() => _remote.checkSession();

  /// 退出登录。
  ///
  /// **远端失败也一定清本地会话**，这是刻意的：用户点的是「退出」，期望的是这台
  /// 设备上不再有会话。若因为断网就把本地会话留着，界面会显示已登录，而服务端
  /// 可能早已把它踢掉——那比直接退出更糟，用户会以为自己还登着。
  ///
  /// 远端错误照常返回给上层，好让调用方能说明「本地已退出，但服务端没应答」，
  /// 而不是静默吞掉一次失败。
  Future<Result<void>> logout() async {
    final result = await _remote.logout();
    await _session.clear();
    return result;
  }

  /// 只丢弃本地会话，不通知服务端。
  ///
  /// 换服务器时用：手上这个令牌是**旧**服务器签发的，新服务器从没听说过它，拿它
  /// 去请求只会得到「令牌无效」——那读起来像是令牌敲错了，而不像是换了地址。
  /// 反过来向新服务器发一次 logout 更荒唐：它没有可注销的东西。
  Future<void> forgetSession() => _session.clear();
}

/// [AuthRepository] 的装配点。
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    ref.watch(authRemoteDatasourceProvider),
    ref.watch(sessionStoreProvider),
  ),
);
