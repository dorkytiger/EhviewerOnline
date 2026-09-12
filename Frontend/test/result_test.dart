import 'package:ehviewer_online/core/exception/global_exception.dart';
import 'package:ehviewer_online/core/util/result_util.dart';
import 'package:flutter_test/flutter_test.dart';

/// [Result] 自身的语义测试。
///
/// 这一组来自一次真实的线上故障：`fold` 曾经按「有没有数据」判断成败，而
/// `Result<void>` 的成功态本来就是 `data == null`，于是**每一次成功的登录**都被
/// 报成「结果中没有数据」，错误还显示在登录页上，看起来像令牌的问题。
///
/// 根因不是某个调用点写错，而是类型自身的契约被写反了——所以测试也钉在类型上，
/// 而不是钉在登录流程上。
void main() {
  group('Result<void>：只关心成败的操作', () {
    test('成功态的 data 就是 null，且 isSuccess 为真', () {
      final result = _ok();

      expect(result.isSuccess, isTrue);
      expect(result.isError, isFalse);
      // 注意：这里**不能**断言 `result.data == null` —— `Result<void>` 的 data 类型
      // 是 void，Dart 不允许把 void 表达式当值使用。正因为 data 连读都读不到，
      // `fold` 里的 null 判断才曾经是唯一的观测点，也才必须判对。
      expect(result.error, isNull);
    });

    test('成功时 fold 必须走 onSuccess，而不是编造一个错误', () {
      var succeeded = false;
      var failed = false;

      final label = _ok().fold<String>(
        (_) {
          succeeded = true;
          return 'ok';
        },
        (error) {
          failed = true;
          return 'error: ${error.message}';
        },
      );

      expect(succeeded, isTrue, reason: '成功的结果不该走错误分支');
      expect(failed, isFalse);
      expect(label, 'ok');
    });

    test('失败时走 onError，并带上原始异常', () {
      final result = _fail();

      final label = result.fold<String>(
        (_) => 'ok',
        (error) => error.message,
      );

      expect(label, '远程请求错误');
      expect(result.isError, isTrue);
      expect(result.error, isA<RemoteException>());
    });
  });

  group('带值的结果', () {
    test('成功时把值交给 onSuccess', () {
      const result = Result<int>.success(42);

      expect(result.data, 42);
      expect(result.fold<String>((v) => '$v', (e) => 'error'), '42');
    });

    test('可空类型拿到 null 也算成功', () {
      // T 装得下 null，所以 null 是合法值，不是错误。
      const result = Result<String?>.success(null);

      expect(result.isSuccess, isTrue);
      expect(result.fold<String>((v) => v ?? '(空)', (e) => 'error'), '(空)');
    });

    test('非空类型却没有值：fold 时如实报错', () {
      // 构造上不该发生（非空 T 不该成功却没有值），但一旦发生必须能定位，
      // 而不是在调用点炸出一个类型转换异常。
      const result = Result<String>.success(null);

      // isError 仍为 false：它只看 error 字段，这是类型的定义（成功就是没错误）。
      expect(result.isError, isFalse);
      // 但 fold 拿不出一个 String 来，所以在这里如实说明。
      expect(
        result.fold<String>((v) => v, (e) => e.message),
        '结果中没有数据',
      );
    });
  });

  group('map', () {
    test('成功时映射值', () {
      const result = Result<int>.success(2);

      expect(result.map((v) => v * 3).data, 6);
    });

    test('失败时原样传递同一个异常对象', () {
      final result = _fail();

      final mapped = result.map((void _) => 'never');

      expect(mapped.isError, isTrue);
      expect(identical(mapped.error, result.error), isTrue);
    });
  });
}

Result<void> _ok() => Result.success(null);

Result<void> _fail() => Result.error(const RemoteException());
