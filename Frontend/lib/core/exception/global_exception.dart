/// 全局通用异常体系。
///
/// 跨层只传递 [GlobalException] 的子类，禁止 `throw Exception('...')` /
/// `throw Error('...')` 充当错误协议；也禁止把 [GlobalException] 再包一层
/// （`Exception(e.toString())` 会丢类型丢堆栈）。
///
/// 约定：每个子类都带**默认中文文案**，调用方只在需要时覆盖 `message`。
library;

/// 所有业务异常的基类。
///
/// 三个字段是跨层通信的最小集合：[message] 给用户看，[exception] 与
/// [stackTrace] 给日志和排查用。原始异常必须保留——把它丢掉之后再想定位
/// 「为什么远程请求失败了」就只能靠猜。
sealed class GlobalException implements Exception {
  const GlobalException({
    required this.message,
    this.exception,
    this.stackTrace,
  });

  /// 面向用户的可读文案。
  final String message;

  /// 原始异常 / 详细信息，只用于日志与诊断。
  final Object? exception;

  /// 原始堆栈。
  final StackTrace? stackTrace;

  @override
  String toString() =>
      '$runtimeType: $message${exception == null ? '' : ' | cause: $exception'}';
}

/// 远程请求失败：网络不可达、超时、非 2xx 响应。
class RemoteException extends GlobalException {
  const RemoteException({
    super.message = '远程请求错误',
    this.statusCode,
    this.code,
    super.exception,
    super.stackTrace,
  });

  /// HTTP 状态码，未经过网络层时为空。
  final int? statusCode;

  /// 服务端返回的机器可读错误码（`error.code`）。
  final String? code;

  bool get isAuthFailure => statusCode == 401;
}

/// 会话缺失或失效。
///
/// 单独成型而不是复用 `RemoteException(statusCode: 401)`，是因为路由要用它
/// 决定跳登录页——按类型判断比按状态码字符串判断更难写错。
class UnauthorizedException extends RemoteException {
  const UnauthorizedException({
    super.message = '登录已过期，请重新登录',
    super.code,
    super.exception,
    super.stackTrace,
  }) : super(statusCode: 401);
}

/// 本地存储读写失败（SharedPreferences 等）。
class LocalStorageException extends GlobalException {
  const LocalStorageException({
    super.message = '本地数据操作失败',
    super.exception,
    super.stackTrace,
  });
}

/// 参数不合法：调用方给了不该给的东西。
class ValidationException extends GlobalException {
  const ValidationException({
    super.message = '参数不合法',
    super.exception,
    super.stackTrace,
  });
}

/// 响应解析失败。
///
/// 与 [RemoteException] 分开，因为两者的排查方向完全不同：一个是网络/服务端
/// 的问题，一个是契约对不上（字段改名、类型变了）。
class ParsingException extends GlobalException {
  const ParsingException({
    super.message = '数据解析失败',
    super.exception,
    super.stackTrace,
  });
}

/// 业务规则不满足。
class BusinessException extends GlobalException {
  const BusinessException({
    super.message = '业务处理失败',
    super.exception,
    super.stackTrace,
  });
}
