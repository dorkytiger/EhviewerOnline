import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../common/config/app_config.dart';
import '../../../core/util/result_util.dart';
import '../model/state/library_filter_state.dart';
import '../model/vo/facets_vo.dart';
import '../model/vo/gallery_detail_vo.dart';
import '../model/vo/gallery_page_vo.dart';
import '../model/vo/server_meta_vo.dart';
import '../repository/library_repository.dart';

/// library 模块对外的唯一入口。
///
/// 其他 feature（如 reader、setting）需要画廊数据时只允许依赖这个 service，
/// 禁止 import library 的 repository / datasource。方法名是跨模块契约，不要
/// 顺手改名。
class LibraryService {
  const LibraryService(this._repository);

  final LibraryRepository _repository;

  /// 按筛选条件拉取一页画廊。
  ///
  /// [cursor] 为空表示从第一页开始；[limit] 默认用全局分页大小。
  Future<Result<GalleryPageVo>> listGalleries(
    LibraryFilterState filter, {
    String cursor = '',
    int limit = AppConfig.pageSize,
    CancelToken? cancelToken,
  }) {
    return _repository.fetchGalleries(
      filter: filter,
      cursor: cursor,
      limit: limit,
      cancelToken: cancelToken,
    );
  }

  /// 拉取单个画廊的详情（含页列表与 `.ehviewer` 元数据）。
  Future<Result<GalleryDetailVo>> galleryDetail(
    int gid, {
    CancelToken? cancelToken,
  }) {
    return _repository.fetchGallery(gid, cancelToken: cancelToken);
  }

  /// 拉取筛选候选项。
  Future<Result<FacetsVo>> facets({CancelToken? cancelToken}) {
    return _repository.fetchFacets(cancelToken: cancelToken);
  }

  /// 拉取服务端元数据、索引统计与功能开关。
  Future<Result<ServerMetaVo>> meta({CancelToken? cancelToken}) {
    return _repository.fetchMeta(cancelToken: cancelToken);
  }

  /// 下载图片原始字节。
  ///
  /// 阅读器需要按页拿整页图，而会话头只有走这里才带得上（web 上是 HttpOnly
  /// cookie，本端是显式 `Cookie` 头），所以不能改用 `Image.network`。
  Future<Result<Uint8List>> imageBytes(
    String url, {
    CancelToken? cancelToken,
  }) {
    return _repository.fetchImageBytes(url, cancelToken: cancelToken);
  }
}

/// 跨模块访问 library 的唯一 provider，由 [libraryRepositoryProvider] 装配。
final libraryServiceProvider = Provider<LibraryService>((ref) {
  return LibraryService(ref.watch(libraryRepositoryProvider));
});
