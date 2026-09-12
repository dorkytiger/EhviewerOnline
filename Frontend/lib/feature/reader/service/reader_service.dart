import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../common/config/app_config.dart';
import '../../../core/exception/global_exception.dart';
import '../../../core/service/api_client.dart';
import '../../../core/service/dio_provider.dart';
import '../../../core/util/result_util.dart';
import '../../library/model/vo/gallery_detail_vo.dart';
import '../../library/service/library_service.dart';
import '../model/state/reader_state.dart';

/// 阅读器的业务用例。
///
/// 预热策略、页索引边界、缺页识别这些与「怎么显示」无关的规则都在这里：
/// 放进 viewmodel，换一套 UI 就得重写一遍；放进 view，就没法单测。
///
/// 画廊数据入口只有 [LibraryService]——reader 不 import library 的
/// repository / datasource / ui，跨模块只走对方 service。[ApiClient] 只用它的
/// 地址解析能力：页的 `PageVo.url` 是服务端相对路径，拼装绝对 URL 属于数据层
/// 的知识，不能散落到 view 里。
class ReaderService {
  const ReaderService(this._library, this._api);

  final LibraryService _library;
  final ApiClient _api;

  /// 拉取画廊详情（含按顺序排列的页列表与 `.ehviewer` 元数据）。
  ///
  /// 直接转发 [LibraryService.galleryDetail]：阅读器不需要对这个响应做裁剪或
  /// 补算，多加一层映射只会多一处会写错的地方。
  Future<Result<GalleryDetailVo>> detail(
    int gid, {
    CancelToken? cancelToken,
  }) {
    return _library.galleryDetail(gid, cancelToken: cancelToken);
  }

  /// 取某一页的原始图片字节。
  ///
  /// [pageIndex] 是页在列表里的**位置**，不是 `PageVo.index`：页码可能有空洞
  /// （服务端少扫到一张），位置才是唯一稳定的寻址方式。越界在这里被显式拒绝，
  /// 而不是让服务端返回 404 之后再说「图片拿不到」。
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

    final url = pages[pageIndex].url;
    if (url.isEmpty) {
      return Future.value(
        const Result.error(ParsingException(message: '该页没有可用的图片地址')),
      );
    }
    return _library.imageBytes(_api.resolve(url), cancelToken: cancelToken);
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
/// [ApiClient] 与 library 用的是同一个 provider：地址变化时两边一起重建，
/// 不会出现详情来自新服务器、图片却还在拉旧地址的错位。
final readerServiceProvider = Provider<ReaderService>((ref) {
  return ReaderService(
    ref.watch(libraryServiceProvider),
    ref.watch(apiClientProvider),
  );
});
