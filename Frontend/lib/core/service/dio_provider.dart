import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'server_address.dart';
import 'session_store.dart';

/// API 客户端。
///
/// 唯一的装配点：地址、Dio 实例、会话存储都在这里注入，业务层不许自己
/// `ApiClient(...)`。地址变化时会重建（它 watch 了 [serverAddressProvider]），
/// 所以改服务器地址不需要重启应用。
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(
    baseUrl: ref.watch(serverAddressProvider),
    dio: Dio(),
    session: ref.watch(sessionStoreProvider),
  );
  // 随容器一起释放底层连接池。
  ref.onDispose(client.close);
  return client;
});
