import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/exception/global_exception.dart';
import '../../../../core/util/result_util.dart';
import '../datasource/local/download_file_local_datasource.dart';
import '../datasource/remote/download_remote_datasource.dart';
import '../enum/download_status.dart';
import '../model/dto/download_page_dto.dart';
import '../model/entity/download_manifest.dart';
import '../model/vo/downloaded_gallery_vo.dart';

/// 下载模块的数据编排：把文件边界与远端边界合起来，并把「失败」翻译成
/// [GlobalException]。
///
/// 它只回答「本机有什么」「写下去成不成」，不决定「本地优先还是回源」——那是业务
/// 规则，在 `DownloadService` 里。
class DownloadRepository {
  const DownloadRepository(this._local, this._remote);

  final DownloadFileLocalDatasource _local;
  final DownloadRemoteDatasource _remote;

  /// 平台是否有可用的文件系统。Web 上整条下载链路都要说「不支持」。
  bool get supported => _local.supported;

  /// 管理列表：每个已有目录一项，按完成时间从新到旧。
  ///
  /// 目录存在但清单读不出来（写了一半就崩、被手工删掉）时按「未完成、0 页」呈现，
  /// 而不是跳过它：跳过会让用户看到一份删不掉、也占着空间的东西。
  Future<Result<List<DownloadedGalleryVo>>> list() async {
    if (!supported) return Result.success(const []);

    final gids = await _local.listedGids();
    final items = <DownloadedGalleryVo>[];
    for (final gid in gids) {
      final manifest = await _local.readManifest(gid) ??
          DownloadManifest(
            gid: gid,
            title: '',
            coverPath: '',
            status: DownloadStatus.partial,
            downloadedAtMs: 0,
            pages: const [],
          );
      items.add(DownloadedGalleryVo(
        manifest: manifest,
        bytes: await _local.galleryBytes(gid),
      ));
    }
    items.sort((a, b) => b.downloadedAtMs.compareTo(a.downloadedAtMs));
    return Result.success(items);
  }

  /// 单本的清单；没有时返回 null。
  Future<Result<DownloadManifest?>> manifest(int gid) async {
    if (!supported) {
      return Result.error(const BusinessException(message: '此平台不支持本地下载'));
    }
    return Result.success(await _local.readManifest(gid));
  }

  /// 写清单。
  Future<Result<void>> writeManifest(DownloadManifest manifest) async {
    final ok = await _local.writeManifest(manifest);
    if (!ok) {
      return Result.error(
        LocalStorageException(
          message: '下载清单写入失败（gid ${manifest.gid}）',
        ),
      );
    }
    return const Result.success(null);
  }

  /// 目录里现存的页文件名集合。
  Future<Set<String>> pageFileNames(int gid) => _local.pageFileNames(gid);

  /// 读本地某一页；没有时返回 null（不是错误——调用方据此回源）。
  Future<Result<Uint8List?>> readPage(int gid, DownloadPageDto page) async {
    if (!supported) return Result.success(null);
    return Result.success(await _local.readPage(gid, page));
  }

  /// 写本地某一页。**失败必须报错**：悄悄跳过会在清单上记下并不存在的页。
  Future<Result<void>> writePage(
    int gid,
    DownloadPageDto page,
    Uint8List bytes,
  ) async {
    final ok = await _local.writePage(gid, page, bytes);
    if (!ok) {
      return Result.error(
        LocalStorageException(
          message: '第 ${page.position + 1} 页写入失败，可能是空间不足',
        ),
      );
    }
    return const Result.success(null);
  }

  /// 收尾：删掉不属于 [keep] 的旧页文件。
  Future<int> deleteStalePages(int gid, Set<String> keep) =>
      _local.deleteStalePages(gid, keep);

  /// 删除一本。
  Future<Result<void>> delete(int gid) async {
    final ok = await _local.deleteGallery(gid);
    if (!ok) {
      return Result.error(
        LocalStorageException(message: '删除失败：无法移除 #$gid 的本地文件'),
      );
    }
    return const Result.success(null);
  }

  /// 删除全部。
  Future<Result<void>> deleteAll() async {
    final ok = await _local.deleteAll();
    if (!ok) {
      return Result.error(const LocalStorageException(message: '删除失败：无法清空下载目录'));
    }
    return const Result.success(null);
  }

  /// 全部下载的实测占用。
  Future<Result<int>> totalBytes() async {
    if (!supported) return Result.success(0);
    final gids = await _local.listedGids();
    var total = 0;
    for (final gid in gids) {
      total += await _local.galleryBytes(gid);
    }
    return Result.success(total);
  }

  /// 回源取一页的字节。
  Future<Result<Uint8List>> fetchPageBytes(
    String url, {
    CancelToken? cancelToken,
  }) {
    return _remote.fetchPageBytes(url, cancelToken: cancelToken);
  }
}

/// 装配点。
final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  return DownloadRepository(
    ref.watch(downloadFileLocalDatasourceProvider),
    ref.watch(downloadRemoteDatasourceProvider),
  );
});
