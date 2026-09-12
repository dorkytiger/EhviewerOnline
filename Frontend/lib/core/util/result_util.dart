import '../exception/global_exception.dart';

/// 可能失败的操作的统一返回值。
///
/// 规则（见全局 AGENTS.md 第 5 节）：
///
/// * 所有**可能失败**的公开方法返回 `Result<T>`；纯计算 / 纯 getter 直接返回值。
/// * 无返回值但有失败可能的操作用 `Result<void>`，禁止 `void doXxx()` 后靠
///   `throw` 通信。
/// * 上层拿到 `Result` **必须先判 [isError]** 再取 [data]，禁止用 `!` / `as`
///   强行解包。
///
/// 不要新造 `Either` / `ApiResponse` 这类平行类型。
///
/// 有一处与规范字面写法不同，是 Dart 语言限制而非取舍：规范里 `Result` 同时
/// 有 `error` 字段和 `static Result.error()` 工厂，但 Dart 不允许静态成员与
/// 实例成员同名。这里用**命名构造器**保留完全一样的调用形式——`Result.error(e)`
/// 和 `Result.success(v)` 照旧，只是它们现在是构造器。
class Result<T> {
  /// 成功。
  const Result.success(this.data) : error = null;

  /// 失败。
  const Result.error(this.error)
      : data = null,
        assert(error != null, 'Result.error 需要一个非空异常');

  /// 成功时的数据；失败时为 null。
  final T? data;

  /// 失败原因；成功时为 null。
  final GlobalException? error;

  bool get isSuccess => error == null;
  bool get isError => error != null;

  /// 成功时映射数据，失败时原样传递错误。
  ///
  /// 让「先判 isError 再取 data」的样板代码不必在每个调用点重复一遍。
  Result<R> map<R>(R Function(T data) transform) {
    final failure = error;
    if (failure != null) {
      return Result<R>.error(failure);
    }
    final value = data;
    if (value == null) {
      // 成功但没有可映射的数据，只可能是 `Result<void>` 这类空结果。
      return Result<R>.error(const BusinessException(message: '结果中没有可映射的数据'));
    }
    return Result<R>.success(transform(value));
  }

  /// 把两种结果收敛成一个值，避免调用方写 if/else。
  R fold<R>(
    R Function(T data) onSuccess,
    R Function(GlobalException error) onError,
  ) {
    final failure = error;
    if (failure != null) {
      return onError(failure);
    }
    final value = data;
    if (value == null) {
      return onError(const BusinessException(message: '结果中没有数据'));
    }
    return onSuccess(value);
  }
}
