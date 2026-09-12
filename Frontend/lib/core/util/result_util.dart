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
  /// 成功时映射数据，失败时原样传递错误。
  ///
  /// 只对**带值**的结果有意义：`Result<void>` 没有可映射的东西，调用它说明用错
  /// 了方法（见 [fold] 关于空结果的说明）。
  Result<R> map<R>(R Function(T data) transform) {
    final failure = error;
    if (failure != null) {
      return Result<R>.error(failure);
    }
    final value = data;
    if (value == null && null is! T) {
      return Result<R>.error(const BusinessException(message: '结果中没有可映射的数据'));
    }
    return Result<R>.success(transform(value as T));
  }

  /// 把两种结果收敛成一个值，避免调用方写 if/else。
  ///
  /// **成功与否只看 [error]，不看 [data]。** [isSuccess] 的定义就是「没有错误」，
  /// 所以这里不能因为 `data == null` 就编造一个错误——`Result<void>` 的成功态本来
  /// 就是 `data == null`（`login` / `logout` 这类只关心成败的操作全是这种形态）。
  /// 早期版本正是按 null 判断，把每一次成功的登录都变成了
  /// 「结果中没有数据」，而且报在登录页上，看起来像令牌的问题。
  ///
  /// 判据改为「[T] 本身能不能装下 null」：
  ///
  /// * `void` 与可空类型能 → 原样交给 [onSuccess]（`void` 是顶类型，转换恒成立）；
  /// * 非空类型不能 → 说明构造这个 `Result` 的地方有问题，如实报错比在调用点炸出
  ///   一个类型错误好定位。
  R fold<R>(
    R Function(T data) onSuccess,
    R Function(GlobalException error) onError,
  ) {
    final failure = error;
    if (failure != null) {
      return onError(failure);
    }
    final value = data;
    if (value == null && null is! T) {
      return onError(const BusinessException(message: '结果中没有数据'));
    }
    return onSuccess(value as T);
  }
}
