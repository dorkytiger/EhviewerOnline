import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../common/config/app_config.dart';
import '../../../core/util/result_util.dart';
import '../datasource/remote/library_remote_datasource.dart';
import '../model/state/library_filter_state.dart';
import '../model/vo/facets_vo.dart';
import '../model/vo/gallery_detail_vo.dart';
import '../model/vo/gallery_page_vo.dart';
import '../model/vo/server_meta_vo.dart';

/// library 数据层的数据编排入口。
///
/// 目前只有远程一个数据源，所以这里的每个方法都是**结果透传**——它存在的意义
/// 是当将来要加本地缓存、离线读取或数据合并时，那套逻辑只有一个落点，而不必
/// 让 service 或 viewmodel 改依赖。
class LibraryRepository {
  const LibraryRepository(this._remote);

  final LibraryRemoteDatasource _remote;

  /// 拉取一页画廊。
  Future<Result<GalleryPageVo>> fetchGalleries({
    required LibraryFilterState filter,
    String cursor = '',
    int limit = AppConfig.pageSize,
    CancelToken? cancelToken,
  }) {
    return _remote.fetchGalleries(
      filter: filter,
      cursor: cursor,
      limit: limit,
      cancelToken: cancelToken,
    );
  }

  /// 拉取单个画廊的详情。
  Future<Result<GalleryDetailVo>> fetchGallery(
    int gid, {
    CancelToken? cancelToken,
  }) {
    return _remote.fetchGallery(gid, cancelToken: cancelToken);
  }

  /// 拉取筛选候选项。
  Future<Result<FacetsVo>> fetchFacets({CancelToken? cancelToken}) {
    return _remote.fetchFacets(cancelToken: cancelToken);
  }

  /// 拉取服务端元数据。
  Future<Result<ServerMetaVo>> fetchMeta({CancelToken? cancelToken}) {
    return _remote.fetchMeta(cancelToken: cancelToken);
  }

  /// 下载图片字节；给阅读器与封面用。
  Future<Result<Uint8List>> fetchImageBytes(
    String url, {
    CancelToken? cancelToken,
  }) {
    return _remote.fetchImageBytes(url, cancelToken: cancelToken);
  }
}

/// 数据编排入口。
final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  return LibraryRepository(ref.watch(libraryRemoteDatasourceProvider));
});
