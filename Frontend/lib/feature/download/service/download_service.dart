import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/exception/global_exception.dart';
import '../../../core/util/result_util.dart';
import '../datasource/local/download_file_local_datasource.dart';
import '../enum/download_outcome.dart';
import '../enum/download_status.dart';
import '../model/dto/download_page_dto.dart';
import '../model/dto/download_request_dto.dart';
import '../../library/enum/availability.dart';
import '../../library/enum/meta_source.dart';
import '../../library/enum/title_source.dart';
import '../../library/model/vo/gallery_detail_vo.dart';
import '../../library/model/vo/gallery_vo.dart';
import '../../library/model/vo/page_vo.dart';
import '../../library/model/vo/spider_info_vo.dart';
import '../model/entity/download_manifest.dart';
import '../model/entity/download_page_entry.dart';
import '../model/vo/downloaded_gallery_vo.dart';
import '../repository/download_repository.dart';

/// 下载模块对外的唯一入口：管理列表、删除、下载、本地优先读页。
///
/// 业务规则都在这里：断点续传的判定、本地副本的身份校验、本地优先还是回源。
/// 这些规则与「怎么显示」无关，放进 viewmodel 就得跟着 UI 重写一遍，放进 view
/// 就没法单测。
class DownloadService {
  const DownloadService(this._repository);

  final DownloadRepository _repository;

  /// 平台是否有文件系统。Web 为 false，界面据此显示「此平台不支持下载」。
  bool get supported => _repository.supported;

  /// 已下载的画廊，新的在前。
  Future<Result<List<DownloadedGalleryVo>>> list() => _repository.list();

  /// 全部下载的占用。
  Future<Result<int>> totalBytes() => _repository.totalBytes();

  /// 删除一本。
  Future<Result<void>> delete(int gid) => _repository.delete(gid);

  /// 删除全部。
  Future<Result<void>> deleteAll() => _repository.deleteAll();

  /// 某一页的字节：**本地优先**。
  ///
  /// 本地副本必须与当前详情描述的是同一张图（见 `DownloadPageEntry.matches`）才会
  /// 被采用；不一致就当没下载过、回源取。宁可多下一次，也不能显示错的一页。
  Future<Result<Uint8List>> pageBytes(
    int gid,
    DownloadPageDto page, {
    CancelToken? cancelToken,
  }) async {
    if (supported) {
      final manifest = await _manifest(gid);
      final entry = manifest?.entryAt(page.position);
      // 身份对不上：位置已经被别的图占了，磁盘上那份是过期数据。
      if (entry != null && entry.matches(page.entry)) {
        final local = await _repository.readPage(gid, page);
        final bytes = local.data;
        if (local.isError) return Result.error(local.error!);
        if (bytes != null && bytes.isNotEmpty) return Result.success(bytes);
      }
    }
    return _repository.fetchPageBytes(page.url, cancelToken: cancelToken);
  }

  /// 下载整本画廊。
  ///
  /// 断点续传：清单在**开始时就写**（status=partial），每一页的身份都在里面；重跑
  /// 时身份一致且文件已存在的页直接跳过。这样中断一次不必把 700 页从头再下一遍，
  /// 而磁盘上的半成品也是一条可解释的记录——列表里显示「未完成」，用户能接着下，
  /// 也能删掉。
  ///
  /// [onProgress] 的 `done` 含跳过的页，所以续传时进度条从断点处长起来而不是从 0。
  ///
  /// 取消与失败都**保留现场**：页文件、清单都不动。
  Future<Result<DownloadOutcome>> download(
    DownloadRequestDto request, {
    void Function(int done, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (!supported) {
      return Result.error(const BusinessException(message: '此平台不支持本地下载'));
    }
    final pages = request.pages;
    if (pages.isEmpty) {
      return Result.error(const BusinessException(message: '这个画廊没有可下载的页'));
    }
    // 开始前就已被取消时不要落清单：那会为一次什么都没做的下载留下一条「未完成」的
    // 记录，用户在管理列表里删不掉疑惑。
    if (cancelToken?.isCancelled ?? false) {
      return const Result.success(DownloadOutcome.cancelled);
    }

    final previous = await _manifest(request.gid);
    // 开始就落清单：中断后这次下载才是可发现的、可续的。
    final started = await _repository.writeManifest(
      DownloadManifest(
        gid: request.gid,
        title: request.title,
        coverPath: request.coverPath,
        status: DownloadStatus.partial,
        downloadedAtMs: DateTime.now().millisecondsSinceEpoch,
        pages: [for (final page in pages) page.entry],
      ),
    );
    if (started.isError) return Result.error(started.error!);

    // 目录里已有哪些页文件：一次遍历，用于判断哪些页不必再下。
    final present = await _repository.pageFileNames(request.gid);
    var done = 0;
    onProgress?.call(done, pages.length);

    for (final page in pages) {
      if (cancelToken?.isCancelled ?? false) {
        return const Result.success(DownloadOutcome.cancelled);
      }

      final name = DownloadFileLocalDatasource.pageFileName(page);
      final recorded = previous?.entryAt(page.position);
      final reusable = present.contains(name) &&
          recorded != null &&
          recorded.matches(page.entry);

      if (reusable) {
        done++;
        onProgress?.call(done, pages.length);
        continue;
      }

      final Result<Uint8List> fetched;
      try {
        fetched = await _repository.fetchPageBytes(
          page.url,
          cancelToken: cancelToken,
        );
      } on DioException catch (e, stackTrace) {
        // 取消是契约上唯一会**抛出**而不是返回 Result 的情况（见 ApiClient.getBytes）
        // ——它必须与网络错误分开，否则用户主动取消会被报成「图片下载失败」。
        if (e.type == DioExceptionType.cancel) {
          return const Result.success(DownloadOutcome.cancelled);
        }
        return Result.error(
          RemoteException(exception: e, stackTrace: stackTrace),
        );
      }
      final bytes = fetched.data;
      if (fetched.isError || bytes == null) {
        return Result.error(
          fetched.error ??
              RemoteException(message: '第 ${page.position + 1} 页的内容为空'),
        );
      }

      final written =
          await _repository.writePage(request.gid, page, bytes);
      if (written.isError) return Result.error(written.error!);

      done++;
      onProgress?.call(done, pages.length);
    }

    // 收尾：删掉不属于这一版页列表的旧文件，免得「已下载」的占用里混着已经不存在的
    // 页；再把清单翻成 complete。
    await _repository.deleteStalePages(
      request.gid,
      {for (final page in pages) DownloadFileLocalDatasource.pageFileName(page)},
    );
    final finished = await _repository.writeManifest(
      DownloadManifest(
        gid: request.gid,
        title: request.title,
        coverPath: request.coverPath,
        status: DownloadStatus.complete,
        downloadedAtMs: DateTime.now().millisecondsSinceEpoch,
        pages: [for (final page in pages) page.entry],
      ),
    );
    if (finished.isError) return Result.error(finished.error!);

    return const Result.success(DownloadOutcome.completed);
  }

  /// 用本地清单重建一份画廊详情，供**服务器不可达时继续阅读**已下载的整本。
  ///
  /// 只填本地有依据的字段：标题与页来自清单，其余元数据（分类、评分、上传者、标签）
  /// 本地根本没有，因此一律落到各枚举的 `unknown` 而不是编一个像模像样的值——
  /// 阅读器只用到标题与页列表，编出来的字段不会显示，但会被下一个人当成事实。
  ///
  /// [PageVo.url] 留空：离线时没有可回源的地址。取页仍然先查本机，本机没有才会去
  /// 拼这个（空）地址并如实报「该页没有可用的图片地址」。
  ///
  /// 没有清单、或清单里一页都没有时返回 null：那不是「离线可读」，而是没有本地副本。
  Future<Result<GalleryDetailVo?>> localDetail(int gid) async {
    final manifest = await _manifest(gid);
    final pages = manifest?.pages ?? const <DownloadPageEntry>[];
    if (manifest == null || pages.isEmpty) return Result.success(null);

    return Result.success(
      GalleryDetailVo(
        gallery: GalleryVo(
          gid: manifest.gid,
          // token 只用于拼服务端地址，离线时不需要，也不该编一个。
          token: '',
          title: manifest.title,
          titleJpn: '',
          titleSource: TitleSource.unknown,
          dirName: '',
          artists: const [],
          groups: const [],
          series: const [],
          events: const [],
          editions: const [],
          category: 0,
          posted: '',
          uploader: '',
          rating: 0,
          simpleLanguage: '',
          label: '',
          state: 0,
          // 这个字段的语义就是「加入下载的时间」，而本地下载时间正是它。
          downloadTimeMs: manifest.downloadedAtMs,
          // 本地清单里有几页就是几页：不写 0，也不假装知道服务端声明了多少。
          pagesExpected: pages.length,
          pagesFound: pages.length,
          totalBytes: 0,
          coverUrl: manifest.coverPath,
          coverKind: '',
          availability: Availability.unknown,
          anomalies: const [],
          metaSource: MetaSource.unknown,
          // 本机确实握着这些页文件，这一项为真不是猜测。
          onDisk: true,
        ),
        pagesDetail: [
          for (var position = 0; position < pages.length; position++)
            PageVo(
              // 本地没有页码空洞：位置就是编号。
              index: position,
              filename: pages[position].filename,
              ext: DownloadFileLocalDatasource.extensionOf(pages[position].filename),
              size: 0,
              mtimeMs: pages[position].mtimeMs,
              url: '',
            ),
        ],
        spiderInfo: SpiderInfoVo.empty,
      ),
    );
  }

  /// 读清单，失败按「没有」处理。
  ///
  /// 读不出清单只是意味着用不上本地副本（回源即可），不该让一次阅读失败——这与
  /// 缩略图缓存的策略一致：缓存坏了不能把一次本来能成功的加载变成失败。
  Future<DownloadManifest?> _manifest(int gid) async {
    final result = await _repository.manifest(gid);
    return result.data;
  }
}

/// 装配点。下载模块不依赖任何 feature：页地址与图片字节都拿 `core` 的 [ApiClient]
/// 自己取（见 `DownloadRemoteDatasource`），详情由调用方摊成请求。
final downloadServiceProvider = Provider<DownloadService>((ref) {
  return DownloadService(ref.watch(downloadRepositoryProvider));
});
