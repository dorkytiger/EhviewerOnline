import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../common/config/app_config.dart';
import '../exception/global_exception.dart';
import '../util/result_util.dart';
import '../util/url_util.dart';
import 'session_store.dart';
import 'sse_client.dart';

/// ehviewer-webd 的 HTTP 传输层。
///
/// 只做传输与错误翻译，不认识任何具体接口：路径拼接、会话重放、Dio 异常到
/// [GlobalException] 的映射都在这里，接口语义（哪些路径、返回什么模型）在
/// 各 feature 的 datasource 里。
///
/// 两条约束决定了它的形状：
///
///  * Web 上会话是浏览器管理的 `HttpOnly` cookie，客户端发不出也读不到；
///    本端没有 cookie jar，所以值由 [SessionStore] 持久化并以 `Cookie` 头
///    重放。
///  * 图片和缩略图 URL 是服务端相对路径（`/img/<gid>/<index>`），必须用与
///    API 相同的 base 解析，否则换了地址图片会指向旧服务器。
class ApiClient {
  ApiClient({
    required String baseUrl,
    required this.dio,
    required this.session,
  }) : baseUrl = normalizeBaseUrl(baseUrl) {
    dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = const Duration(seconds: 15)
      // 宽松：一张整页图或首次缩略图渲染可能很慢，走隧道时尤其如此。
      ..receiveTimeout = const Duration(seconds: 90)
      // 非 2xx 交给下面显式处理，这样能读到服务端的错误体，而不是被 Dio
      // 的通用文案盖掉。全部放行、由 `_errorFrom` 决定。
      ..validateStatus = (int? status) => true;

    dio.options.headers.addAll(<String, Object?>{
      'Accept': 'application/json',
    });

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (!AppConfig.isWeb) {
            final value = session.read();
            if (value != null) {
              options.headers['Cookie'] = '${SessionStore.cookieName}=$value';
            }
          }
          handler.next(options);
        },
      ),
    );
  }

  /// 归一化后的服务器地址，末尾无 `/`。
  ///
  /// 在构造函数里归一化，而不是指望装配点先做好：`resolve()` 会直接拼字符串，
  /// 一个尾斜杠就会拼出 `//img/...`，而直接 new 出来的实例没有任何理由知道
  /// 调用方是否记得归一化。
  final String baseUrl;

  /// 传输层依赖，由装配点注入（见 `core/service/dio_provider.dart`）。
  final Dio dio;
  final SessionStore session;

  /// 把服务端相对路径解析成绝对 URL。
  String resolve(String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return path.startsWith('/') ? '$baseUrl$path' : '$baseUrl/$path';
  }

  // --- 请求 ----------------------------------------------------------------

  /// GET 一个 JSON 对象。
  Future<Result<Map<String, dynamic>>> getJson(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) =>
      _send(method: 'GET', path: path, query: query, cancelToken: cancelToken);

  /// POST 一个 JSON 对象。
  Future<Result<Map<String, dynamic>>> postJson(
    String path, {
    Object? body,
    CancelToken? cancelToken,
  }) =>
      _send(method: 'POST', path: path, data: body, cancelToken: cancelToken);

  /// 下载原始字节，供图片使用。
  ///
  /// 图片走 Dio 而不是 `Image.network`，因为请求必须带上会话：cookie 只在
  /// Web 上自动，本端需要显式头，而 `Image.network` 设不了头。
  Future<Result<Uint8List>> getBytes(
    String url, {
    CancelToken? cancelToken,
  }) async {
    Response<List<int>> response;
    try {
      response = await dio.get<List<int>>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          headers: const {'Accept': 'image/*'},
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      return Result.error(_transportError(e));
    }

    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      return Result.error(_errorFrom(response, status));
    }
    final data = response.data;
    if (data == null || data.isEmpty) {
      return Result.error(const ParsingException(message: '图片内容为空'));
    }
    return Result.success(data is Uint8List ? data : Uint8List.fromList(data));
  }

  /// 订阅 `/api/v1/events` 的 SSE 流。
  ///
  /// 自行重连，退避有上限。服务端每 30 分钟主动断一次（让会话重新校验、让
  /// 中间设备拿到干净的连接），所以断流是预期行为而不是异常，不能当错误报
  /// 给用户。
  ///
  /// 这个流永远不会自己结束；取消 [cancelToken] 或停止监听才会终止。
  Stream<SseEvent> streamEvents({CancelToken? cancelToken}) async* {
    final parser = SseParser();
    var backoff = const Duration(seconds: 1);

    while (true) {
      if (cancelToken?.isCancelled ?? false) return;

      Response<ResponseBody> response;
      try {
        response = await dio.get<ResponseBody>(
          '/api/v1/events',
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            headers: const {'Accept': 'text/event-stream'},
            receiveTimeout: null, // 流不能被超时切断
          ),
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) return;
        // 服务器不可达。等待重试而不是结束流：在第一次失败就放弃的客户端
        // 会在此后整个会话里收不到任何更新。
        await _sleep(backoff, cancelToken);
        backoff = _nextBackoff(backoff);
        continue;
      }

      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        final error = _errorFrom(response, status);
        // 401 表示会话已死，重试只会空转，交给调用方去重新登录。
        if (error is RemoteException && error.isAuthFailure) {
          throw error;
        }
        await _sleep(backoff, cancelToken);
        backoff = _nextBackoff(backoff);
        continue;
      }

      final body = response.data;
      if (body == null) {
        await _sleep(backoff, cancelToken);
        backoff = _nextBackoff(backoff);
        continue;
      }

      var sawEvent = false;
      try {
        // body.stream 产出 Uint8List。allowMalformed 让「多字节字符被切在
        // 分块边界上」不至于抛异常：整体字节序列仍然合法，只是不在这一块里。
        await for (final chunk in body.stream) {
          final text = utf8.decode(chunk, allowMalformed: true);
          for (final event in parser.add(text)) {
            // 连接健康就重置退避，短暂抖动不会导致接下来 30 秒都连不回来。
            sawEvent = true;
            backoff = const Duration(seconds: 1);
            yield event;
          }
        }
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) return;
      } on Exception {
        // 中途断流在弱网下是常态，落到下面重连即可。
      }

      for (final event in parser.flush()) {
        yield event;
      }
      if (!sawEvent) {
        await _sleep(backoff, cancelToken);
        backoff = _nextBackoff(backoff);
      }
    }
  }

  /// 关闭底层客户端。
  void close() => dio.close(force: true);

  // --- 内部 ----------------------------------------------------------------

  Future<Result<Map<String, dynamic>>> _send({
    required String method,
    required String path,
    Map<String, dynamic>? query,
    Object? data,
    CancelToken? cancelToken,
  }) async {
    Response<dynamic> response;
    try {
      response = await dio.request<dynamic>(
        path,
        queryParameters: query,
        data: data == null ? null : jsonEncode(data),
        cancelToken: cancelToken,
        options: Options(
          method: method,
          contentType: data == null ? null : Headers.jsonContentType,
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      return Result.error(_transportError(e));
    }

    _captureSession(response.headers.value('set-cookie'));

    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      return Result.error(_errorFrom(response, status));
    }

    // 已经把「解不出来」也收敛成 Result 了，所以这里直接透传，_send 不需要
    // 再判断 null。
    return _decodeObject(response.data, path);
  }

  /// 把响应体解成 JSON 对象，失败时返回 null。
  ///
  /// 2xx 但响应体不是 JSON 对象属于契约违约，明说比三层之后抛一个类型转换
  /// 错误要有用得多。
  /// 把响应体解成 JSON 对象。
  ///
  /// **任何**失败都返回 `Result.error`，绝不抛出。这个方法的两条失败路径
  /// （不是 JSON、是 JSON 但不是对象）如果一条返回 `Result.error`、另一条抛
  /// 异常，调用方就得不到编译器的提醒：`Future<Result<T>>` 的签名不会提示它
  /// 需要 try/catch，于是只判 `result.isError` 的 viewmodel 会直接崩掉，三态
  /// 闭环里根本没有 error 态。代理或网关返回 `200 + text/html` 时就是这条路径。
  Result<Map<String, dynamic>> _decodeObject(Object? body, String path) {
    if (body == null) return Result.success(const <String, dynamic>{});
    if (body is Map<String, dynamic>) return Result.success(body);
    if (body is Map) return Result.success(body.cast<String, dynamic>());
    if (body is String) {
      if (body.isEmpty) return Result.success(const <String, dynamic>{});
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) return Result.success(decoded);
        if (decoded is Map) return Result.success(decoded.cast<String, dynamic>());
      } on FormatException catch (e, st) {
        return Result.error(ParsingException(
          message: '服务器返回了非 JSON 内容（$path）',
          exception: e,
          stackTrace: st,
        ));
      }
    }
    return Result.error(
      ParsingException(message: '服务器返回了意外的响应格式（$path）'),
    );
  }

  /// 从 `Set-Cookie` 里取出会话值并持久化。
  ///
  /// 一个 cookie 值本身可以包含 `=`，所以只按**第一个** `=` 切分，值到第一个
  /// `;` 为止。
  void _captureSession(String? rawSetCookie) {
    if (AppConfig.isWeb || rawSetCookie == null) return;
    for (final part in rawSetCookie.split(',')) {
      final trimmed = part.trim();
      if (!trimmed.startsWith('${SessionStore.cookieName}=')) continue;
      final afterName = trimmed.substring(SessionStore.cookieName.length + 1);
      final semi = afterName.indexOf(';');
      final value = semi == -1 ? afterName : afterName.substring(0, semi);
      if (value.isNotEmpty) {
        session.write(value);
      }
      return;
    }
  }

  /// 把一个非 2xx 响应翻译成业务异常。
  GlobalException _errorFrom(Response<dynamic> response, int status) {
    String? code;
    String? serverMessage;

    final body = response.data;
    Map<String, dynamic>? json;
    if (body is Map<String, dynamic>) {
      json = body;
    } else if (body is String && body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) json = decoded;
      } on FormatException {
        // 不是 JSON，退回按状态码给文案。
      }
    }

    final error = json?['error'];
    if (error is Map<String, dynamic>) {
      code = error['code']?.toString();
      final message = error['message']?.toString();
      if (message != null && message.isNotEmpty) serverMessage = message;
    }

    final friendly =
        serverMessage == null ? _statusMessage(status) : _friendlyMessage(code, serverMessage);

    if (status == 401) {
      return UnauthorizedException(message: friendly, code: code);
    }
    return RemoteException(message: friendly, statusCode: status, code: code);
  }

  /// 把 Dio 的传输错误翻译成业务异常。
  GlobalException _transportError(DioException e) {
    final message = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        '连接超时，请检查服务器是否可达',
      DioExceptionType.connectionError => '无法连接到服务器 ${Uri.parse(baseUrl).host}',
      DioExceptionType.badCertificate => 'HTTPS 证书校验失败',
      DioExceptionType.cancel => '请求已取消',
      DioExceptionType.badResponse => _statusMessage(e.response?.statusCode ?? 0),
      // transformTimeout 是响应转换超预算，属于解码问题而不是网络问题。
      DioExceptionType.transformTimeout => '处理服务器响应超时',
      DioExceptionType.unknown => '网络错误：${e.message ?? '未知原因'}',
    };
    return RemoteException(message: message, exception: e, stackTrace: e.stackTrace);
  }

  String _friendlyMessage(String? code, String serverMessage) => switch (code) {
        'unauthorized' => '令牌无效或会话已过期',
        'not_found' => '未找到该内容',
        'bad_cursor' => '分页游标已失效，请重新加载',
        'no_cover' => '该画廊没有可用的封面（本地无图片）',
        'thumb_too_large' => '封面图片过大，无法生成缩略图',
        'forbidden' => '该操作不被允许',
        // 其它一律照服务端的说法展示：改写一条我们并不理解的错误文案只会
        // 丢掉信息。
        _ => serverMessage,
      };

  String _statusMessage(int status) => switch (status) {
        400 => '请求无效',
        401 => '需要登录',
        403 => '拒绝访问',
        404 => '未找到该内容',
        413 => '请求内容过大',
        422 => '无法处理该图片',
        500 => '服务器内部错误',
        502 || 503 || 504 => '服务器暂时不可用（正在同步或重建索引？）',
        _ => '请求失败（HTTP $status）',
      };

  static Duration _nextBackoff(Duration current) {
    final next = current * 2;
    const max = Duration(seconds: 30);
    return next > max ? max : next;
  }

  static Future<void> _sleep(Duration d, CancelToken? token) async {
    // 轮询而不是和信号竞争：重连延迟不是延迟敏感路径，这样取消响应更简单。
    final deadline = DateTime.now().add(d);
    while (DateTime.now().isBefore(deadline)) {
      if (token?.isCancelled ?? false) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
