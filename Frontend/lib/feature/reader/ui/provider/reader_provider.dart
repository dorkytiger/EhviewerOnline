import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../common/config/app_config.dart';
import '../../../library/model/vo/gallery_detail_vo.dart';
import '../../model/state/reader_state.dart';
import '../../service/reader_service.dart';

/// 画廊详情的三态查询。
///
/// 用 `FutureProvider.family` 而不是自建 viewmodel：这里没有本地状态要维护，
/// `.when` 天然给出 loading / success / error 三态，重试就是
/// `ref.invalidate`。
final readerDetailProvider =
    FutureProvider.family<GalleryDetailVo, int>((ref, gid) async {
  final result = await ref.watch(readerServiceProvider).detail(gid);
  if (result.isError) {
    // 交给 riverpod 的错误态承载：把 GlobalException 原样抛出，view 用
    // messageOf 取文案，不需要在这里再包一层。
    throw result.error!;
  }
  return result.data!;
});

/// 单页图片字节。
///
/// 预热与当前页读取共用这一个 provider，于是「预热过的页再显示时不会二次请求」
/// 由缓存本身保证，而不是两套代码之间的约定。
///
/// **回收靠 autoDispose 加真实的 watch，不靠手动 invalidate。** 它的两个消费者
/// 都是 `ref.watch`：显示中的页由 [ReaderPageImage] watch，预热窗口内的页由
/// `ReaderPreload` watch。页滑出这两者之外就失去最后一个监听者，Riverpod 自然
/// 把它丢掉——常驻内存的图片数量因此与 [AppConfig.readerPreloadRadius] 成正比，
/// 而不是与「读过多少页」成正比。
///
/// 之前这里用 `keepAlive` 钉住、再由 `ReaderPreload.didUpdateWidget` 手动
/// `invalidate` 回收。那条路会在**构建阶段**触发 provider 失效
/// （`setState() or markNeedsBuild() called during build`），而且两份机制表达的
/// 是同一件事——留一份就够了。
final readerPageBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, ({int gid, int position})>((ref, key) async {
  final detail = await ref.watch(readerDetailProvider(key.gid).future);
  final result = await ref
      .watch(readerServiceProvider)
      .pageBytes(detail, key.position);

  if (result.isError) {
    // 失败不进入成功态：错误页上的「重试」必须真的重新发请求。
    throw result.error!;
  }
  return result.data!;
});

/// 阅读位置与预热开关的 viewmodel。
///
/// 只管「现在在第几页、总共几页、能不能预热」这类 UI 状态。页边界夹取、预热
/// 窗口、缺页识别都在 [ReaderService]，这里不出现第二套页导航规则。
///
/// 刻意不是 family：应用里同一时刻只有一个阅读页在树上，按 gid 分实例只会多
/// 一份永远不会被读到的状态。
class ReaderPositionController extends Notifier<ReaderState> {
  @override
  ReaderState build() => const ReaderState();

  /// 详情到达（或刷新）后绑定总页数，并把位置收进合法范围。
  ///
  /// [initialPosition] 为空时保留当前位置：SSE 推送的索引变更会让详情重建，
  /// 不能把用户正在读的页打回第 0 页。
  void bindTotal(int total, {int? initialPosition}) {
    final requested = initialPosition ?? state.pageIndex;
    state = state.copyWith(
      total: total,
      pageIndex: clampToRange(requested, 0, total - 1),
      preloadEnabled: total > 0,
    );
  }

  /// 翻到 [position]（页在列表里的位置，从 0 开始）；越界会夹回边界。
  void goTo(int position) {
    if (!state.hasPages) return;
    final clamped = clampToRange(position, 0, state.total - 1);
    if (clamped == state.pageIndex) return;
    state = state.copyWith(pageIndex: clamped);
  }

  /// 关闭预热。
  ///
  /// 单独暴露是为了在详情出错、或服务端重扫导致页数骤减之后仍能关掉它，不留下
  /// 一个「以为还在预热」的开关。
  void disablePreload() {
    if (!state.preloadEnabled) return;
    state = state.copyWith(preloadEnabled: false);
  }
}

final readerPositionProvider =
    NotifierProvider<ReaderPositionController, ReaderState>(
  ReaderPositionController.new,
);

/// 当前页两侧需要预热的页位置，升序。
///
/// 预热半径只在这里决定（[AppConfig.readerPreloadRadius]）：页面预热与缓存回收
/// 都看这个 provider，两边不会各算一套。
final readerPreloadWindowProvider = Provider<List<int>>((ref) {
  final state = ref.watch(readerPositionProvider);
  if (!state.preloadEnabled || !state.hasPages) return const [];
  return ReaderService.preloadWindow(
    state.clampedIndex,
    state.total,
    AppConfig.readerPreloadRadius,
  );
});
