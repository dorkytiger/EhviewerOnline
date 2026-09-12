import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../common/config/app_config.dart';
import '../../../../core/util/message_util.dart';
import '../../../auth/ui/provider/auth_provider.dart';
import '../../model/state/library_list_state.dart';
import '../../model/vo/gallery_vo.dart';
import '../../service/library_service.dart';
import 'library_filter_provider.dart';

/// 分页累积的画廊列表。
///
/// `build` watch 了筛选状态，所以改筛选会从头重跑——这是有意的：把上一个查询的
/// 第二页追加到新查询的第一页后面，会悄悄产生一份错误的列表。
class LibraryListController extends AsyncNotifier<LibraryListState> {
  @override
  Future<LibraryListState> build() async {
    // 会话每次读都要把关，登录/退出都会改变结果集。
    ref.watch(authProvider.select((s) => s.status));
    final filter = ref.watch(libraryFilterProvider);

    final result = await ref.read(libraryServiceProvider).listGalleries(filter);
    // Result → AsyncValue：失败在这里转成 error 状态（view 用 .when 渲染三态），
    // 异常不越过 provider 边界往上抛。
    return result.fold(
      (page) => LibraryListState(
        galleries: page.items,
        total: page.total,
        nextCursor: page.nextCursor,
        indexedAtMs: page.indexedAtMs,
        snapshotAtMs: page.snapshotAtMs,
      ),
      (error) => throw error,
    );
  }

  /// 取下一页并追加。
  ///
  /// 防并发：快速滚动会在一帧里触发很多次，没有这道闸门它们会拿同一个游标各发
  /// 一次请求，然后把同一批行重复追加。
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;

    state = AsyncData(current.copyWith(
      loadingMore: true,
      clearLoadMoreError: true,
    ));

    final result = await ref.read(libraryServiceProvider).listGalleries(
          ref.read(libraryFilterProvider),
          cursor: current.nextCursor,
          limit: AppConfig.pageSize,
        );
    if (!ref.mounted) return;

    state = result.fold(
      (page) => AsyncData(
        LibraryListState(
          galleries: [...current.galleries, ...page.items],
          total: page.total,
          nextCursor: page.nextCursor,
          indexedAtMs: page.indexedAtMs,
          snapshotAtMs: page.snapshotAtMs,
        ),
      ),
      // 失败只记在 banner 上：第三页失败就把已加载的两页丢掉是敌意行为。
      (error) => AsyncData(current.copyWith(
        loadingMore: false,
        loadMoreError: messageOf(error),
      )),
    );
  }

  /// 从第一页重新拉取，用于用户主动刷新。
  Future<void> refresh() async {
    state = const AsyncLoading<LibraryListState>();
    state = await AsyncValue.guard(build);
  }

  /// 后台变更后就地更新，不重置用户的翻页位置。
  ///
  /// 直接 refresh 会把用户已经滚过的每一页打回第一页，而这不是他们要求的：他们
  /// 没点刷新，丢掉阅读位置比这条更新本身更烦人。
  ///
  /// 所以只重取第一页并把它镜像到已持有的行上，再补上刷新没覆盖到的新条目。新
  /// 画廊按加入时间排序、默认又是最新在前，所以真正的新条目通常落在第一页、立刻
  /// 可见；位置更深的条目会在用户下次刷新时出现。这是有意的取舍：不跳滚动位置，
  /// 代价是排序把它放到很靠后的新条目不会秒现。
  Future<void> applyLiveChange() async {
    final current = state.value;
    if (current == null) {
      // 从未加载成功（或处于错误态）：没有位置需要保，正常刷新即可。
      await refresh();
      return;
    }

    final result = await ref.read(libraryServiceProvider).listGalleries(
          ref.read(libraryFilterProvider),
          limit: AppConfig.pageSize,
        );
    if (!ref.mounted) return;

    final error = result.error;
    if (error != null) {
      // 后台刷新失败绝不能扰动屏幕上已有的内容。
      state = AsyncData(current.copyWith(loadMoreError: messageOf(error)));
      return;
    }

    final page = result.data!;
    final fresh = <int, GalleryVo>{for (final g in page.items) g.gid: g};
    final covered = <int>{};
    final merged = <GalleryVo>[];

    // 先按原顺序替换已有行，这样列表的顺序和数量不会在用户眼皮底下跳。
    for (final existing in current.galleries) {
      final replacement = fresh[existing.gid];
      if (replacement != null) {
        merged.add(replacement);
        covered.add(existing.gid);
      } else {
        merged.add(existing);
      }
    }
    // 再把刷新页面里没见过的新条目放到最前面。
    final newcomers =
        page.items.where((g) => !covered.contains(g.gid)).toList(growable: false);

    state = AsyncData(
      LibraryListState(
        galleries: [...newcomers, ...merged],
        total: page.total,
        // 保留原游标：列表尾部没有被重新取过，它仍是正确的续页点。
        nextCursor: current.nextCursor,
        indexedAtMs: page.indexedAtMs,
        snapshotAtMs: page.snapshotAtMs,
      ),
    );
  }
}

final galleryListProvider =
    AsyncNotifierProvider<LibraryListController, LibraryListState>(
  LibraryListController.new,
);
