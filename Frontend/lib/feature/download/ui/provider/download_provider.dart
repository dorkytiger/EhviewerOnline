import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/util/result_util.dart';
import '../../model/vo/downloaded_gallery_vo.dart';
import '../../service/download_service.dart';

/// 平台是否支持本地下载（Web 为 false）。
///
/// 单独做成 provider，是因为 view 不能直接碰 service——而「这个平台能不能下载」是
/// 界面分支，必须有个只读的东西让它 watch。
final downloadSupportedProvider = Provider<bool>((ref) {
  return ref.watch(downloadServiceProvider).supported;
});

/// 已下载画廊的列表（管理页的查询 + 两个写操作）。
///
/// 列表与删除放在一个 viewmodel 里：删除之后列表必须刷新，两者分开就会出现「删了
/// 但列表还在」的窗口期，而用户会把那个窗口期当成删除失败。
class DownloadListController extends AsyncNotifier<List<DownloadedGalleryVo>> {
  @override
  Future<List<DownloadedGalleryVo>> build() async {
    final result = await ref.watch(downloadServiceProvider).list();
    // Result → AsyncValue：失败转成 error 状态由 view 渲染三态，异常不越过 provider
    // 边界往上抛。
    return result.fold((items) => items, (error) => throw error);
  }

  /// 删除一本。**先删文件再刷新列表**：列表还在但文件没了，用户点进去会读不到，
  /// 比列表显示旧数据更糟。
  Future<Result<void>> delete(int gid) async {
    final result = await ref.read(downloadServiceProvider).delete(gid);
    if (result.isError) return result;
    ref.invalidateSelf();
    return const Result.success(null);
  }

  /// 删除全部。
  Future<Result<void>> deleteAll() async {
    final result = await ref.read(downloadServiceProvider).deleteAll();
    if (result.isError) return result;
    ref.invalidateSelf();
    return const Result.success(null);
  }

  /// 用户主动刷新。
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }
}

final downloadListProvider =
    AsyncNotifierProvider<DownloadListController, List<DownloadedGalleryVo>>(
  DownloadListController.new,
);

/// 已下载的总占用。
///
/// 直接对列表里的实测值求和，而不是再去遍历一次目录：同一个数字在两处各算一遍，
/// 迟早出现「列表加起来 1.2 GB、标题写着 1.1 GB」。
final downloadTotalBytesProvider = Provider<int>((ref) {
  final items = ref.watch(downloadListProvider).value ?? const [];
  return items.fold(0, (sum, item) => sum + item.bytes);
});

/// 单本画廊的下载记录；没下载过时为 null。
final downloadedGalleryProvider =
    Provider.family<DownloadedGalleryVo?, int>((ref, gid) {
  final items = ref.watch(downloadListProvider).value ?? const [];
  for (final item in items) {
    if (item.gid == gid) return item;
  }
  return null;
});
