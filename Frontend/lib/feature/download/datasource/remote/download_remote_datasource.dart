import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/exception/global_exception.dart';
import '../../../../core/service/api_client.dart';
import '../../../../core/service/dio_provider.dart';
import '../../../../core/util/result_util.dart';

/// 取页图片的远端接口域。
///
/// 自己封装而不是复用 library 的 datasource：跨 feature 只能依赖对方的 service，
/// 而 library 的 service 没有「按 URL 取字节」这个能力暴露出来（它只按页取，那是
/// 阅读器的语义）。这里的接口面只有一个：拿一张图。
///
/// **不改用 `Image.network`**：图片请求必须带会话（Web 上是 HttpOnly cookie，本端是
/// 显式 `Cookie` 头），而 `Image.network` 设不了头。
class DownloadRemoteDatasource {
  const DownloadRemoteDatasource(this._api);

  final ApiClient _api;

  /// 取一页的原始字节。
  ///
  /// [path] 是服务端相对路径（`PageVo.url` 那个形状）。拼绝对地址属于数据层的
  /// 知识，不能散落到调用方——换域名、改端口时只应该有这一处要改。
  Future<Result<Uint8List>> fetchPageBytes(
    String path, {
    CancelToken? cancelToken,
  }) {
    if (path.isEmpty) {
      return Future.value(const Result.error(ParsingException(message: '该页没有可用的图片地址')));
    }
    return _api.getBytes(_api.resolve(path), cancelToken: cancelToken);
  }
}

/// 远端数据源。地址变化时 [apiClientProvider] 会重建，这里跟着换实例。
final downloadRemoteDatasourceProvider =
    Provider<DownloadRemoteDatasource>((ref) {
  return DownloadRemoteDatasource(ref.watch(apiClientProvider));
});
