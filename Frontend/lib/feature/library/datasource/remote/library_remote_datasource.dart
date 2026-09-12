import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../common/config/app_config.dart';
import '../../../../core/service/api_client.dart';
import '../../../../core/service/dio_provider.dart';
import '../../../../core/util/result_util.dart';
import '../../model/state/library_filter_state.dart';
import '../../model/vo/facets_vo.dart';
import '../../model/vo/gallery_detail_vo.dart';
import '../../model/vo/gallery_page_vo.dart';
import '../../model/vo/server_meta_vo.dart';

/// library 模块的远程数据源（`/api/v1` 的画廊接口域）。
///
/// 只负责「路径 + 查询参数 + 解析」三件事：传输、会话重放、错误翻译由
/// [ApiClient] 承担，所以这里不做任何 try/catch，`Result` 原样往上透传。
class LibraryRemoteDatasource {
  const LibraryRemoteDatasource(this._api);

  final ApiClient _api;

  /// 拉取一页画廊。
  ///
  /// [filter] 的重复标签参数由 `toQuery()` 生成，分页参数只在这里拼。
  Future<Result<GalleryPageVo>> fetchGalleries({
    required LibraryFilterState filter,
    String cursor = '',
    int limit = AppConfig.pageSize,
    CancelToken? cancelToken,
  }) async {
    final result = await _api.getJson(
      '/api/v1/galleries',
      query: <String, dynamic>{
        ...filter.toQuery(),
        'limit': limit,
        if (cursor.isNotEmpty) 'cursor': cursor,
      },
      cancelToken: cancelToken,
    );
    return result.map(GalleryPageVo.fromJson);
  }

  /// 拉取单个画廊及其页列表。
  Future<Result<GalleryDetailVo>> fetchGallery(
    int gid, {
    CancelToken? cancelToken,
  }) async {
    final result = await _api.getJson(
      '/api/v1/galleries/$gid',
      cancelToken: cancelToken,
    );
    return result.map(GalleryDetailVo.fromJson);
  }

  /// 拉取筛选候选项。
  Future<Result<FacetsVo>> fetchFacets({CancelToken? cancelToken}) async {
    final result = await _api.getJson(
      '/api/v1/facets',
      cancelToken: cancelToken,
    );
    return result.map(FacetsVo.fromJson);
  }

  /// 拉取服务端元数据、索引统计与功能开关。
  Future<Result<ServerMetaVo>> fetchMeta({CancelToken? cancelToken}) async {
    final result = await _api.getJson('/api/v1/meta', cancelToken: cancelToken);
    return result.map(ServerMetaVo.fromJson);
  }

  /// 下载图片原始字节。
  ///
  /// 图片必须带会话（本端 cookie 不是自动的），所以走 [ApiClient.getBytes]
  /// 而不是 `Image.network`。
  Future<Result<Uint8List>> fetchImageBytes(
    String url, {
    CancelToken? cancelToken,
  }) {
    return _api.getBytes(url, cancelToken: cancelToken);
  }
}

/// 远程数据源。地址变化时 [apiClientProvider] 会重建，这里跟着换实例。
final libraryRemoteDatasourceProvider = Provider<LibraryRemoteDatasource>((ref) {
  return LibraryRemoteDatasource(ref.watch(apiClientProvider));
});
