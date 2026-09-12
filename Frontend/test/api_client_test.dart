import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ehviewer_online/core/exception/global_exception.dart';
import 'package:ehviewer_online/core/service/api_client.dart';
import 'package:ehviewer_online/core/service/session_store.dart';
import 'package:ehviewer_online/core/util/result_util.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// [ApiClient] 的传输层契约测试。
///
/// 用真实进程内 `HttpServer` + 真实 Dio，而不是 mock Dio：mock 只能证明「我们
/// 以为 Dio 会这么发」，而这里要钉住的是整条栈的真实行为——header 大小写、重复
/// 查询参数的编码、`Set-Cookie` 的解析、状态码与非 JSON 响应体。fixture 抄自真实
/// ehviewer-webd 响应，服务端契约改了而客户端没跟上时，这里先红。
void main() {
  late SessionStore session;

  setUp(() async {
    // 每个用例一份全新存储：会话是跨请求的全局副作用，共用一个实例会让
    // 「上一个用例登录过」变成下一个用例的隐含前提，用例就不能单独运行了。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    session = SessionStore(await SharedPreferences.getInstance());
  });

  ApiClient newClient(String baseUrl) =>
      ApiClient(baseUrl: baseUrl, dio: Dio(), session: session);

  /// 取出一次预期失败的返回值；成功则直接让用例失败。
  Future<GlobalException> failureOf<T>(Future<Result<T>> future) async {
    final result = await future;
    expect(result.isError, isTrue, reason: '预期请求失败，实际返回成功');
    return result.error!;
  }

  /// 起一个固定返回 [status] 的服务器，并返回指向它的客户端。
  ///
  /// 清理通过 `addTearDown` 注册，调用方不必自己管——「状态码 → 异常映射」
  /// 这类用例因此只需要三行。
  Future<ApiClient> clientReturning(
    int status, {
    String body = '',
    Map<String, String> headers = _jsonHeaders,
  }) async {
    final server = await _startServer(
      (_) async => http.Response(body, status, headers: headers),
    );
    addTearDown(server.close);
    final client = newClient(server.baseUrl);
    addTearDown(client.close);
    return client;
  }

  group('请求与响应', () {
    test('getJson 拼出路径与查询参数，并解出 JSON 对象', () async {
      Uri? seen;
      String? seenAccept;
      final server = await _startServer((request) async {
        seen = request.url;
        seenAccept = request.headers['accept'];
        return _jsonResponse({'ok': true, 'n': 1});
      });
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);

      final result = await client.getJson(
        '/api/v1/galleries',
        query: {'q': 'chinese', 'limit': 25},
      );

      expect(result.isSuccess, isTrue);
      expect(result.data, {'ok': true, 'n': 1});
      expect(seen!.path, '/api/v1/galleries');
      expect(seen!.queryParameters, {'q': 'chinese', 'limit': '25'});
      // Accept 是客户端自报的能力，写死在装配点；散到各调用点就会漂移。
      expect(seenAccept, 'application/json');
    });

    test('getJson 把列表值编码成重复参数', () async {
      Uri? seen;
      final server = await _startServer((request) async {
        seen = request.url;
        return _jsonResponse({'items': <Object>[], 'total': 0});
      });
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);

      await client.getJson(
        '/api/v1/galleries',
        query: {
          'artist': ['a', 'b'],
        },
      );

      // `?artist=a&artist=b` 是服务端读标签的方式；编码成 `artist[]=` 或
      // `artist=a,b` 都会让筛选静默失效（返回空列表而不是报错）。
      expect(seen!.queryParametersAll['artist'], ['a', 'b']);
      expect(seen!.query, contains('artist=a&artist=b'));
    });

    test('postJson 以 JSON 编码请求体并声明 content-type', () async {
      String? seenMethod;
      String? seenBody;
      String? seenContentType;
      final server = await _startServer((request) async {
        seenMethod = request.method;
        seenBody = request.body;
        seenContentType = request.headers['content-type'];
        return _jsonResponse({'authenticated': true});
      });
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);

      final result = await client.postJson(
        '/api/v1/auth/login',
        body: {'token': 'the-token'},
      );

      expect(result.isSuccess, isTrue);
      expect(seenMethod, 'POST');
      expect(jsonDecode(seenBody!), {'token': 'the-token'});
      expect(seenContentType, contains('application/json'));
    });

    test('2xx 的空响应体是合法的空对象', () async {
      final client = await clientReturning(200);

      final result = await client.getJson('/api/v1/auth/logout');

      // 没有 body 的 2xx（例如 logout）不该被当成解析失败。
      expect(result.isSuccess, isTrue);
      expect(result.data, isEmpty);
    });
  });

  group('非 2xx 状态码 → 业务异常', () {
    test('400 没有错误体时按状态码给出通用文案', () async {
      final client = await clientReturning(400);

      final error = await failureOf(client.getJson('/api/v1/galleries'));

      expect(error, isA<RemoteException>());
      final remote = error as RemoteException;
      expect(remote.statusCode, 400);
      expect(remote.message, '请求无效');
      expect(remote.code, isNull);
    });

    test('服务端的 error.message 优先于通用文案', () async {
      final client = await clientReturning(
        400,
        body: _errorBody('bad_request', 'category must be an integer'),
      );

      final error = await failureOf(client.getJson('/api/v1/galleries'));

      final remote = error as RemoteException;
      expect(remote.statusCode, 400);
      // 我们并不理解这个 code，照抄服务端的说法比套一句「请求无效」更有信息。
      expect(remote.message, 'category must be an integer');
      expect(remote.code, 'bad_request');
    });

    test('已知 error.code 用本端中文文案，且压过服务端英文', () async {
      final client = await clientReturning(
        400,
        body: _errorBody('bad_cursor', 'cursor fingerprint mismatch'),
      );

      final error = await failureOf(client.getJson('/api/v1/galleries'));

      final remote = error as RemoteException;
      expect(remote.code, 'bad_cursor');
      expect(remote.message, '分页游标已失效，请重新加载');
    });

    test('401 映射成 UnauthorizedException 且 isAuthFailure 为真', () async {
      final client = await clientReturning(
        401,
        body: _errorBody('unauthorized', 'invalid token'),
      );

      final error = await failureOf(client.getJson('/api/v1/auth/me'));

      // 路由按类型判断是否跳登录页，所以 401 必须是专门的子类，而不是
      // `RemoteException(statusCode: 401)`。
      expect(error, isA<UnauthorizedException>());
      final unauthorized = error as UnauthorizedException;
      expect(unauthorized.statusCode, 401);
      expect(unauthorized.isAuthFailure, isTrue);
      expect(unauthorized.code, 'unauthorized');
      expect(unauthorized.message, '令牌无效或会话已过期');
    });

    test('401 没有错误体时仍然是需要登录', () async {
      final client = await clientReturning(401);

      final error = await failureOf(client.getJson('/api/v1/auth/me'));

      final unauthorized = error as UnauthorizedException;
      expect(unauthorized.isAuthFailure, isTrue);
      expect(unauthorized.message, '需要登录');
    });

    test('403 拒绝访问', () async {
      final client = await clientReturning(403);

      final error = await failureOf(client.getJson('/api/v1/reindex'));

      expect((error as RemoteException).statusCode, 403);
      expect(error.message, '拒绝访问');
    });

    test('403 forbidden 用本端文案', () async {
      final client = await clientReturning(
        403,
        body: _errorBody('forbidden', 'reindex is limited to local callers'),
      );

      final error = await failureOf(client.getJson('/api/v1/reindex'));

      expect(error.message, '该操作不被允许');
    });

    test('404 not_found 覆盖服务端英文', () async {
      final client = await clientReturning(
        404,
        body: _errorBody('not_found', 'no such gallery'),
      );

      final error = await failureOf(client.getJson('/api/v1/galleries/999'));

      final remote = error as RemoteException;
      expect(remote.statusCode, 404);
      expect(remote.code, 'not_found');
      expect(remote.message, '未找到该内容');
    });

    test('500 服务器内部错误', () async {
      final client = await clientReturning(
        500,
        body: _errorBody('internal', 'cannot issue session'),
      );

      final error = await failureOf(client.getJson('/api/v1/meta'));

      final remote = error as RemoteException;
      expect(remote.statusCode, 500);
      // `internal` 没有专门文案，照服务端的话展示。
      expect(remote.message, 'cannot issue session');
    });

    test('503 说明服务器正在同步或重建索引', () async {
      final client = await clientReturning(503);

      final error = await failureOf(client.getJson('/api/v1/meta'));

      expect((error as RemoteException).statusCode, 503);
      expect(error.message, '服务器暂时不可用（正在同步或重建索引？）');
    });

    test('错误体不是 JSON 时退回状态码文案', () async {
      final client = await clientReturning(
        500,
        body: 'boom',
        headers: const {'content-type': 'text/plain'},
      );

      final error = await failureOf(client.getJson('/api/v1/meta'));

      // 反代或网关可能吐 HTML；解析错误体失败不该变成一个更模糊的错误。
      expect(error, isA<RemoteException>());
      expect((error as RemoteException).statusCode, 500);
      expect(error.message, '服务器内部错误');
    });
  });

  group('会话 cookie', () {
    test('Set-Cookie 落盘到 SessionStore，并在后续请求以 Cookie 头重放', () async {
      String? loginCookie;
      String? meCookie;
      final server = await _startServer((request) async {
        if (request.url.path == '/api/v1/auth/login') {
          loginCookie = request.headers['cookie'];
          return _jsonResponse(
            {'authenticated': true, 'expires_in_secs': 2592000},
            headers: {
              'set-cookie': 'ehw_session=abc123.signature; HttpOnly; Secure; SameSite=Lax; Path=/',
            },
          );
        }
        meCookie = request.headers['cookie'];
        return _jsonResponse({'authenticated': true});
      });
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);

      final login = await client.postJson(
        '/api/v1/auth/login',
        body: {'token': 't'},
      );
      expect(login.isSuccess, isTrue);
      expect(loginCookie, isNull, reason: '登录前没有任何会话可重放');
      expect(session.read(), 'abc123.signature');

      // 本端没有 cookie jar，后续请求必须由客户端显式重放，否则除登录外的
      // 每个请求都会 401。
      await client.getJson('/api/v1/auth/me');
      expect(meCookie, 'ehw_session=abc123.signature');
    });

    test('没有会话时不发送 Cookie 头', () async {
      String? cookie;
      final server = await _startServer((request) async {
        cookie = request.headers['cookie'];
        return _jsonResponse({'authenticated': false});
      });
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);

      await client.getJson('/api/v1/auth/me');

      expect(cookie, isNull);
    });

    test('名字不匹配的 Set-Cookie 不覆盖已有会话', () async {
      await session.write('old-value');
      final server = await _startServer((request) async {
        return _jsonResponse(
          {'ok': true},
          headers: {'set-cookie': 'other_cookie=zzz; Path=/'},
        );
      });
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);

      await client.getJson('/api/v1/meta');

      // 「最后一个 cookie 就是会话」会在服务端多加一个 cookie 时把用户踢下线。
      expect(session.read(), 'old-value');
    });
  });

  group('resolve', () {
    test('拼出相对路径，保留绝对 URL 与空串', () {
      final client = newClient('https://example.com');
      addTearDown(client.close);

      expect(client.baseUrl, 'https://example.com');
      expect(
        client.resolve('/img/1234567/0'),
        'https://example.com/img/1234567/0',
      );
      expect(
        client.resolve('img/1234567/0'),
        'https://example.com/img/1234567/0',
      );
      // 服务端可能直接给出 CDN 绝对地址，二次拼接会毁掉它。
      expect(
        client.resolve('https://cdn.example.org/a.jpg'),
        'https://cdn.example.org/a.jpg',
      );
      expect(client.resolve(''), '');
    });
  });

  group('响应体解析', () {
    test('JSON 数组不是对象时报 ParsingException', () async {
      final client = await clientReturning(200, body: jsonEncode([1, 2, 3]));

      final result = await client.getJson('/api/v1/galleries');

      // 契约是 JSON 对象；给它一个数组说明服务端换了形状，不能当成空对象放行。
      expect(result.isError, isTrue);
      expect(result.error, isA<ParsingException>());
    });

    test('非 JSON 的 2xx 响应以 ParsingException 报错', () async {
      final server = await _startServer(
        (_) async => http.Response(
          '<html>a proxy ate this</html>',
          200,
          headers: const {'content-type': 'text/html'},
        ),
      );
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);

      // 注意：lib 目前在 `_decodeObject` 里**抛出**这个异常，而不是返回
      // `Result.error`（JSON 但不是对象那条路径才返回 Result）。两条通道都
      // 接住，断言错误本身——契约要求的是「拿到 ParsingException」，见回报。
      Object? surfaced;
      try {
        final result = await client.getJson('/api/v1/meta');
        surfaced = result.error;
      } on GlobalException catch (e) {
        surfaced = e;
      }

      expect(surfaced, isA<ParsingException>());
    });
  });

  group('getBytes', () {
    test('拿到原始字节并声明图片 Accept', () async {
      final bytes = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
      String? seenAccept;
      final server = await _startServer((request) async {
        seenAccept = request.headers['accept'];
        return http.Response.bytes(
          bytes,
          200,
          headers: const {'content-type': 'image/png'},
        );
      });
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);

      final result = await client.getBytes('/img/1234567/0');

      expect(result.isSuccess, isTrue);
      expect(result.data, orderedEquals(bytes));
      // 图片请求要覆盖掉全局的 application/json，否则服务端可能协商出错误格式。
      expect(seenAccept, 'image/*');
    });

    test('空响应体报 ParsingException 而不是返回 0 字节图', () async {
      final server = await _startServer(
        (_) async => http.Response.bytes(
          <int>[],
          200,
          headers: const {'content-type': 'image/png'},
        ),
      );
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);

      final error = await failureOf(client.getBytes('/img/1234567/0'));

      // 0 字节会渲染成一张破图；明确报错让 UI 有机会显示占位并重试。
      expect(error, isA<ParsingException>());
      expect(error.message, '图片内容为空');
    });

    test('非 2xx 映射成远程异常', () async {
      final client = await clientReturning(
        404,
        body: _errorBody('not_found', 'no such page'),
      );

      final error = await failureOf(client.getBytes('/img/1234567/99'));

      expect(error, isA<RemoteException>());
      expect((error as RemoteException).statusCode, 404);
    });
  });

  group('传输故障', () {
    test('连接被拒绝时翻译成可读文案，而不是泄漏 SocketException', () async {
      // 先占一个端口再释放：这样拿到的端口一定没人监听，也不依赖某个约定俗成
      // 的端口号（在别人机器上可能真的在跑服务）。
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close(force: true);

      final client = newClient('http://127.0.0.1:$deadPort');
      addTearDown(client.close);

      final error = await failureOf(client.getJson('/api/v1/meta'));

      expect(error, isA<RemoteException>());
      expect(error.message, contains('无法连接'));
      // 原始 Dio 异常必须保留，排查时要知道是哪一类失败。
      expect(error.exception, isA<DioException>());
    });

    test('响应超时翻译成可读文案', () async {
      final server = await _startServer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return _jsonResponse({'ok': true});
      });
      addTearDown(server.close);

      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      // 把 90s 默认值压短，用例不必真的等；Dio 从 options 读它。
      client.dio.options.receiveTimeout = const Duration(milliseconds: 100);

      final error = await failureOf(client.getJson('/api/v1/meta'));

      expect(error, isA<RemoteException>());
      expect(error.message, contains('连接超时'));
    });
  });
}

// --- fixtures --------------------------------------------------------------

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// 服务端的错误响应体（与 `Backend/internal/httpapi` 的 `apiError` 对齐）。
String _errorBody(String code, String message) => jsonEncode({
  'error': {'code': code, 'message': message},
});

http.Response _jsonResponse(
  Object body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode(body),
  status,
  headers: {..._jsonHeaders, ...headers},
);

// --- helpers ---------------------------------------------------------------

class _TestServer {
  _TestServer(this._server);

  final HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

/// 起一个真实 HTTP 服务器，由 [handler] 决定响应。
///
/// 用真实 socket 而不是 mock Dio，契约测试才覆盖得到传输层：header 大小写、
/// cookie 往返、`_send` 里的状态码处理与非 JSON 响应。
Future<_TestServer> _startServer(
  Future<http.Response> Function(http.Request request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final forwarded = http.Request(request.method, request.uri)..body = body;
      // HttpHeaders 没有 toMap()，forEach 是唯一的枚举方式；同名多值合并成
      // 一个头，和真实客户端发出的形态一致。
      request.headers.forEach((name, values) {
        forwarded.headers[name] = values.join(',');
      });

      final response = await handler(forwarded);
      request.response.statusCode = response.statusCode;
      response.headers.forEach((key, value) {
        // Set-Cookie 允许出现多次，必须 add；其余头是普通覆盖。
        if (key.toLowerCase() == 'set-cookie') {
          request.response.headers.add(key, value);
        } else {
          request.response.headers.set(key, value);
        }
      });
      request.response.add(response.bodyBytes);
      await request.response.close();
    } catch (_) {
      // 客户端超时/取消后连接已经关闭，这时写响应会抛。这是用例编排的预期
      // 副作用，不该变成监听回调里的未处理异步异常，把无关用例一起带崩。
      try {
        await request.response.close();
      } catch (_) {
        return;
      }
    }
  });
  return _TestServer(server);
}
