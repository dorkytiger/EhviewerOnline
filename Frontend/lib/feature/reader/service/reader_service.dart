import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../common/config/app_config.dart';
import '../../../core/exception/global_exception.dart';
import '../../../core/util/result_util.dart';
import '../../download/model/dto/download_page_dto.dart';
import '../../download/service/download_service.dart';
import '../../library/model/vo/gallery_detail_vo.dart';
import '../../library/service/library_service.dart';
import '../model/state/reader_state.dart';

/// 阅读器的业务用例。
///
/// 预热策略、页索引边界、缺页识别这些与「怎么显示」无关的规则都在这里：
/// 放进 viewmodel，换一套 UI 就得重写一遍；放进 view，就没法单测。
///
/// 画廊数据入口只有 [LibraryService]，取图入口只有 [DownloadService]——reader
/// 不 import 别人的 repository / datasource / ui，跨模块只走对方 service。页的
/// `PageVo.url` 是服务端相对路径，拼装绝对 URL 属于数据层知识，因此也由对方负责
/// （见 `DownloadRemoteDatasource`），阅读器只交出「哪一页」。
class ReaderService {
  const ReaderService(this._library, this._download);

  final LibraryService _library;
  final DownloadService _download;

  /// 拉取画廊详情（含按顺序排列的页列表与 `.ehviewer` 元数据）。
  ///
  /// 优先问服务端；**服务器不可达时退到本机已下载的副本**（见
  /// `DownloadService.localDetail`）。没有这一步，「下载」就只是省流量——断网后连
  /// 打开一本已经完整下载过的画廊都做不到，而页图明明就在磁盘上。
  ///
  /// 退到本地副本时仍然返回成功，不把远程错误抛上去：用户要的是继续读这一本，
  /// 而不是一个「网络错误」的错误页。本地也没有副本时才如实报原始远程错误。
  Future<Result<GalleryDetailVo>> detail(
    int gid, {
    CancelToken? cancelToken,
  }) async {
    final remote = await _library.galleryDetail(gid, cancelToken: cancelToken);
    if (remote.isSuccess) return remote;

    final local = await _download.localDetail(gid);
    final fallback = local.data;
    if (fallback != null) return Result.success(fallback);
    return remote;
  }

  /// 取某一页的原始图片字节。
  ///
  /// [pageIndex] 是页在列表里的**位置**，不是 `PageVo.index`：页码可能有空洞
  /// （服务端少扫到一张），位置才是唯一稳定的寻址方式。越界在这里被显式拒绝，
  /// 而不是让服务端返回 404 之后再说「图片拿不到」。
  ///
  /// 字节本身由 `download` 模块取：只有它知道本机有没有这一页，也只有它会去校验
  /// 本地副本与当前详情描述的是不是同一张图（见 `DownloadService.pageBytes`）。
  /// 阅读器不自己拼路径、也不自己判断本地是否存在——那两件事各有一处实现才可能
  /// 保持一致。
  Future<Result<Uint8List>> pageBytes(
    GalleryDetailVo detail,
    int pageIndex, {
    CancelToken? cancelToken,
  }) {
    final pages = detail.pagesDetail;
    if (pageIndex < 0 || pageIndex >= pages.length) {
      return Future.value(
        Result.error(
          ValidationException(
            message: '页位置越界：$pageIndex（共 ${pages.length} 页）',
          ),
        ),
      );
    }

    final page = pages[pageIndex];
    // 这里**不**再提前拒绝空 URL：离线重建的详情本来就没有远程地址，而本机可能
    // 正好有这一页。是否有地址、本机有没有，统一由 download 模块判断（它先查本机，
    // 再对空地址报「该页没有可用的图片地址」）。
    return _download.pageBytes(
      detail.gallery.gid,
      DownloadPageDto(
        position: pageIndex,
        filename: page.filename,
        mtimeMs: page.mtimeMs,
        url: page.url,
      ),
      cancelToken: cancelToken,
    );
  }

  /// 当前页两侧需要预热的页位置，升序。
  ///
  /// 纯函数，可单测。半径来自 [AppConfig.readerPreloadRadius]，刻意只覆盖两侧
  /// 各两页：阅读器在手机上被 OOM 杀掉，几乎都是因为同时握住了太多全尺寸图片。
  ///
  /// 总数为 0 或半径为负时返回空表；首尾两页的窗口自然被截断。
  static List<int> preloadWindow(int current, int total, int radius) {
    if (total <= 0 || radius < 0) return const [];
    final from = clampToRange(current - radius, 0, total - 1);
    final to = clampToRange(current + radius, 0, total - 1);
    return [for (var i = from; i <= to; i++) i];
  }

  /// 页位置与文件编号不一致时的说明。
  ///
  /// 返回 null 表示这一页的文件编号与位置一致，没什么要提示的。服务端列出的
  /// 页数可能少于元数据声明的页数，此时 `index != position`；静默显示一张
  /// 「第 N 张」，用户根本无从知道中间少了一页。
  static ReaderGap? gapAt(GalleryDetailVo detail, int position) {
    final pages = detail.pagesDetail;
    if (position < 0 || position >= pages.length) return null;
    final page = pages[position];
    if (page.index == position) return null;
    return ReaderGap(position: position, pageIndex: page.index);
  }
}

/// 页编号空洞的说明对象。
///
/// 用对象而不是「拼好的字符串」在 service 与 view 之间传递：文案属于展示层，
/// service 只负责指出事实，这样同一条信息在窄屏和宽屏上可以换措辞。
class ReaderGap {
  const ReaderGap({required this.position, required this.pageIndex});

  /// 该页在列表里的位置（从 0 开始）。
  final int position;

  /// 该页的文件编号（从 0 开始）。
  final int pageIndex;

  /// 列表里的第几张（从 1 开始），给用户看的序号。
  int get displayNumber => position + 1;

  /// 文件编号对应的序号（从 1 开始）。
  int get fileNumber => pageIndex + 1;
}

/// reader 模块的装配点。
///
/// 取图用的 download service 内部也依赖同一个 `ApiClient` provider：地址变化时
/// 两边一起重建，不会出现详情来自新服务器、图片却还在拉旧地址的错位。
final readerServiceProvider = Provider<ReaderService>((ref) {
  return ReaderService(
    ref.watch(libraryServiceProvider),
    ref.watch(downloadServiceProvider),
  );
});
