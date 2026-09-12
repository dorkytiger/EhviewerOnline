import '../../../library/model/vo/gallery_detail_vo.dart';
import 'download_page_dto.dart';

/// 一次「把整本画廊下到本地」的请求。
///
/// 由调用方（画廊详情页的 viewmodel）从已经拿到的详情构造出来，而不是让下载模块
/// 自己去请求详情：详情已经在上层手里，再请求一次不但多一次往返，还会出现「界面
/// 显示 120 页、下载却按 118 页算」这种两处事实不一致。
///
/// 代价是请求可能已经过期（服务端重扫过）。这由身份校验兜住：过期页的身份对不上
/// 本地文件，会被重新下载。
class DownloadRequestDto {
  const DownloadRequestDto({
    required this.gid,
    required this.title,
    required this.coverPath,
    required this.pages,
  });

  final int gid;

  /// 存进清单的标题，用于列表显示（见 `DownloadManifest.title`）。
  final String title;

  /// 封面在服务端的相对路径，可为空。
  final String coverPath;

  /// 按顺序排列的页。
  final List<DownloadPageDto> pages;

  /// 从画廊详情构造请求。
  ///
  /// 详情已经在详情页手里，再让下载模块自己请求一次不但多一次往返，还会出现
  /// 「界面显示 120 页、下载却按 118 页算」这种两处事实不一致。代价是请求可能已经
  /// 过期（服务端重扫过）——这由身份校验兜住：身份对不上的页会被重新下载。
  ///
  /// 位置取**列表下标**而不是 `PageVo.index`：页码可能有空洞，位置才是阅读器与
  /// 本地文件共用的寻址方式。
  factory DownloadRequestDto.fromGalleryDetail(GalleryDetailVo detail) {
    final gallery = detail.gallery;
    final pages = detail.pagesDetail;
    return DownloadRequestDto(
      gid: gallery.gid,
      title: gallery.displayTitle,
      coverPath: gallery.coverUrl,
      pages: [
        for (var position = 0; position < pages.length; position++)
          DownloadPageDto(
            position: position,
            filename: pages[position].filename,
            mtimeMs: pages[position].mtimeMs,
            url: pages[position].url,
          ),
      ],
    );
  }
}
