import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../library/model/vo/gallery_detail_vo.dart';
import '../../../library/service/library_service.dart';

/// 下载页需要的画廊详情（标题、页数、每页大小）。
///
/// 下载模块自己取详情，而不是让详情页把对象传进来：路由只能传路径参数。跨模块访问
/// 走 library 的 service（全局规范唯一允许的方式），不 import 它的 repository /
/// datasource / ui。
///
/// 与阅读器的详情是两次独立查询：两个页面不会同时存在，硬凑一份共享缓存只会多一个
/// 需要失效的副本。
final downloadDetailProvider =
    FutureProvider.family<GalleryDetailVo, int>((ref, gid) async {
  final result = await ref.watch(libraryServiceProvider).galleryDetail(gid);
  // Result → AsyncValue：失败转成 error 状态交给 CustomErrorWidget，异常不越过
  // provider 边界。
  return result.fold((detail) => detail, (error) => throw error);
});
