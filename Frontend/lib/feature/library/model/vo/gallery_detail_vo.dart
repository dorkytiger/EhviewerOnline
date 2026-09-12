import 'gallery_vo.dart';
import 'json_coerce.dart';
import 'page_vo.dart';
import 'spider_info_vo.dart';

/// 详情接口返回的画廊：列表字段 + 页列表 + `.ehviewer` 元数据 + 相邻 gid。
class GalleryDetailVo {
  const GalleryDetailVo({
    required this.gallery,
    required this.pagesDetail,
    required this.spiderInfo,
    this.prevGid = 0,
    this.nextGid = 0,
  });

  /// 详情响应把列表投影平铺在同一个 JSON 对象里，所以这里复用
  /// [GalleryVo.fromJson] 解析同一份对象。
  final GalleryVo gallery;

  /// 按顺序排列的页。页码可能有空洞，所以一律按下标寻址，不要假设
  /// index 等于位置。
  final List<PageVo> pagesDetail;

  final SpiderInfoVo spiderInfo;

  /// 同一排序下相邻的画廊 gid；0 表示没有相邻项（服务端 `omitempty`）。
  final int prevGid;
  final int nextGid;

  factory GalleryDetailVo.fromJson(Map<String, dynamic> json) => GalleryDetailVo(
        gallery: GalleryVo.fromJson(json),
        pagesDetail: mapListOr(json['pages_detail'])
            .map(PageVo.fromJson)
            .toList(growable: false),
        spiderInfo: SpiderInfoVo.fromJson(mapOr(json['spider_info'])),
        prevGid: intOr(json['prev_gid']),
        nextGid: intOr(json['next_gid']),
      );
}
