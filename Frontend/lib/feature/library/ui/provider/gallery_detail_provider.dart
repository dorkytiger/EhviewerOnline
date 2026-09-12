import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/vo/gallery_detail_vo.dart';
import '../../service/library_service.dart';

/// 单个画廊的详情（含页列表与 `.ehviewer` 元数据）。
///
/// family 按 gid 缓存：阅读器和详情页都要它，同一个 gid 在一屏生命周期里只会
/// 发一次请求。
final galleryDetailProvider =
    FutureProvider.family<GalleryDetailVo, int>((ref, gid) async {
  final result = await ref.watch(libraryServiceProvider).galleryDetail(gid);
  return result.fold((detail) => detail, (error) => throw error);
});
