/// 会话校验所处的阶段。
///
/// [checking] 必须是独立状态，不能拿「未登录」兼任。冷启动时本地根本判断不了
/// 会话是否有效：Web 上 cookie 是 `HttpOnly`，读不到；本端虽然有值，但服务端
/// 可能早已作废它。唯一可靠的答案来自服务端。
///
/// 这段等待期间路由要**停在原地**（启动占位页）。若把初始态当成未登录，每个
/// 已登录用户冷启动都会先闪一下登录页，再跳回图库——那是纯粹的视觉噪音，还会
/// 让人以为会话丢了。
enum AuthStatus {
  /// 正在向服务端确认会话；路由应停留在启动占位页，不要渲染登录页。
  checking,

  /// 会话有效。
  authenticated,

  /// 没有会话，或服务端明确否认了当前会话。
  unauthenticated,
}

/// 认证状态。
///
/// 不可变：所有变更都经 [copyWith] 产生新实例，避免 view 与 viewmodel 共享同一
/// 个可变对象而互相踩踏。
class AuthState {
  const AuthState({required this.status, this.error, this.submitting = false});

  /// 冷启动初始态：尚未知道会话是否有效。
  const AuthState.checking() : this(status: AuthStatus.checking);

  /// 未登录态，可携带一条给用户看的失败原因。
  const AuthState.unauthenticated({String? error})
    : this(status: AuthStatus.unauthenticated, error: error);

  final AuthStatus status;

  /// 最近一次认证失败的原因，展示在登录表单里。
  final String? error;

  /// 登录请求是否在途：按钮据此禁用，避免重复提交。
  final bool submitting;

  bool get isAuthenticated => status == AuthStatus.authenticated;

  bool get isChecking => status == AuthStatus.checking;

  /// 拷贝更新。
  ///
  /// [clearError] 不能省：`error: null` 与「不修改 error」在 Dart 里无法区分，
  /// 而登录重试时必须把上一条错误清掉，否则用户会在输入框下方一直看到一条已经
  /// 不成立的提示。
  AuthState copyWith({
    AuthStatus? status,
    String? error,
    bool clearError = false,
    bool? submitting,
  }) {
    return AuthState(
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
      submitting: submitting ?? this.submitting,
    );
  }
}
