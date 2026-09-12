import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/custom_empty_widget.dart';
import '../../../../common/widget/custom_error_widget.dart';
import '../../../../common/widget/f_dialog_content.dart';
import '../../../../core/util/format_util.dart';
import '../../enum/gallery_sort.dart';
import '../../model/state/library_filter_state.dart';
import '../../model/state/library_list_state.dart';
import '../../model/vo/server_meta_vo.dart';
import '../provider/library_filter_provider.dart';
import '../provider/library_list_provider.dart';
import '../provider/live_updates_provider.dart';
import '../provider/server_meta_provider.dart';
import '../widget/filter_sheet.dart';
import '../widget/gallery_card.dart';

/// 图库：带搜索、排序与筛选的画廊网格。
class LibraryView extends ConsumerStatefulWidget {
  const LibraryView({super.key});

  @override
  ConsumerState<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends ConsumerState<LibraryView> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _search.text = ref.read(libraryFilterProvider).text;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    // 远在触底之前就开始取，用户滚到下一页时它通常已经在那儿了。
    if (remaining < _loadMoreThreshold) {
      unawaited(ref.read(galleryListProvider.notifier).loadMore());
    }
  }

  /// 防抖：否则每敲一个键就是一次请求。
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      if (!mounted) return;
      ref.read(libraryFilterProvider.notifier).setText(value);
      _scroll.jumpTo(0);
    });
  }

  Future<void> _refresh() => ref.read(galleryListProvider.notifier).refresh();

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(galleryListProvider);
    final filter = ref.watch(libraryFilterProvider);

    return FScaffold(
      header: FHeader(
        title: const Text('EhViewer 在线库'),
        suffixes: [
          FHeaderAction(
            icon: const Icon(FLucideIcons.refreshCw),
            onPress: _refresh,
          ),
        ],
      ),
      child: Column(
        children: [
          _Toolbar(
            controller: _search,
            onChanged: _onSearchChanged,
            sort: filter.sort,
            onSortChanged: (sort) =>
                ref.read(libraryFilterProvider.notifier).setSort(sort),
            activeFilters: filter.activeCount,
            onOpenFilters: () => showFilterSheet(context),
          ),
          Expanded(
            child: async.when(
              // 刷新时保留旧数据，避免整屏闪成骨架。
              skipLoadingOnRefresh: true,
              loading: () => const Center(child: FCircularProgress()),
              error: (error, stack) =>
                  CustomErrorWidget(error: error, onRetry: _refresh),
              data: (state) => state.galleries.isEmpty
                  ? _EmptyView(filter: filter)
                  : _GalleryGrid(
                      state: state,
                      scroll: _scroll,
                      // push 而不是 go：详情页下面必须留着图库，否则系统返回手势会退出应用。
                      onTapGallery: (gid) => context.push('/gallery/$gid'),
                    ),
            ),
          ),
          if (async.value?.loadMoreError != null)
            _LoadMoreErrorBanner(message: async.value!.loadMoreError!),
          _StalenessBar(
            state: async.value,
            meta: ref.watch(serverMetaProvider).value,
            live: ref.watch(liveUpdatesProvider),
          ),
        ],
      ),
    );
  }
}

/// 触底前多久开始取下一页。
const double _loadMoreThreshold = 800;

/// 搜索防抖窗口。
const Duration _searchDebounce = Duration(milliseconds: 350);

/// 搜索框 + 筛选入口 + 排序。
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.onChanged,
    required this.sort,
    required this.onSortChanged,
    required this.activeFilters,
    required this.onOpenFilters,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final GallerySort sort;
  final ValueChanged<GallerySort> onSortChanged;
  final int activeFilters;
  final VoidCallback onOpenFilters;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: FTextField(
                  control: FTextFieldControl.managed(
                    controller: controller,
                    // control 回调给的是 TextEditingValue，不是 String。
                    onChange: (value) => onChanged(value.text),
                  ),
                  hint: '搜索标题、上传者、标签或 gid',
                  prefixBuilder: (context, style, _) => const Padding(
                    // 图标和输入文字之间要留出可读的间隔；贴着放会让占位文案
                    // 看起来像是图标的一部分。
                    padding: EdgeInsets.only(
                      right: AppSpacing.lg,
                      left: AppSpacing.lg,
                    ),
                    child: Icon(FLucideIcons.search, size: AppIcon.sm),
                  ),
                  clearable: (value) => value.text.isNotEmpty,
                ),
              ),
              SizedBox(width: AppSpacing.sm),
              // 生效中的筛选数量直接写在按钮上而不是做成角标：文字本身就比一个
              // 小圆点更清楚。
              FButton(
                variant: activeFilters > 0
                    ? FButtonVariant.primary
                    : FButtonVariant.outline,
                onPress: onOpenFilters,
                prefix: const Icon(FLucideIcons.listFilter, size: AppIcon.sm),
                child: Text(activeFilters > 0 ? '筛选 $activeFilters' : '筛选'),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm),
          // 排序单独一行：塞进上面那行要么挤掉搜索框，要么得给它写死一个宽度，
          // 而写死的宽度在大字号或窄屏上都会溢出。
          FSelect<GallerySort>(
            label: const Text('排序'),
            items: {
              for (final option in GallerySort.values) option.label: option,
            },
            control: FSelectControl<GallerySort>.lifted(
              value: sort,
              onChange: (value) {
                if (value != null) onSortChanged(value);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryGrid extends StatelessWidget {
  const _GalleryGrid({
    required this.state,
    required this.scroll,
    required this.onTapGallery,
  });

  final LibraryListState state;
  final ScrollController scroll;
  final void Function(int gid) onTapGallery;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 目标是约 180 逻辑像素一格，但**不少于两列**：单列大封面在手机和桌面
        // 窗口上都是浪费。
        final columns = (constraints.maxWidth / 200).floor().clamp(2, 8);
        return GridView.builder(
          controller: scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.md,
            AppSpacing.xl,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: AppSpacing.md,
            mainAxisSpacing: AppSpacing.md,
            // 封面 + 两行文字；留出余量，免得大字号下标题被裁掉。
            childAspectRatio: 0.62,
          ),
          itemCount: state.galleries.length + (state.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= state.galleries.length) {
              return const Center(child: FCircularProgress());
            }
            final gallery = state.galleries[index];
            return GalleryCard(
              gallery: gallery,
              onTap: () => onTapGallery(gallery.gid),
            );
          },
        );
      },
    );
  }
}

/// 空态。区分「库里就没有」和「筛选筛没了」——两者的下一步动作完全不同。
class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.filter});

  final LibraryFilterState filter;

  @override
  Widget build(BuildContext context) {
    final filtered = !filter.isEmpty;
    return CustomEmptyWidget(
      icon: filtered ? FLucideIcons.listFilter : FLucideIcons.images,
      message: filtered ? '没有符合条件的结果' : '库是空的',
      hint: filtered ? '试着放宽筛选条件' : '请确认 Syncthing 已完成同步，或服务器已导出数据库快照',
    );
  }
}

class _LoadMoreErrorBanner extends StatelessWidget {
  const _LoadMoreErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Container(
      width: double.infinity,
      color: theme.colors.error,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Text(
        '加载下一页失败：$message',
        style: theme.typography.body.xs.copyWith(
          color: theme.colors.errorForeground,
        ),
      ),
    );
  }
}

/// 数据新鲜度。
///
/// 这是界面上最诚实的一条：元数据来自用户在手机上导出的快照，它有多旧就显示
/// 多旧；索引也只新到最后一次文件扫描。把任何一个说成「实时」，屏幕上其它数字
/// 就都成了误导。
class _StalenessBar extends StatelessWidget {
  const _StalenessBar({
    required this.state,
    required this.meta,
    required this.live,
  });

  final LibraryListState? state;
  final ServerMetaVo? meta;
  final LiveStatus live;

  @override
  Widget build(BuildContext context) {
    if (state == null && meta == null) return const SizedBox.shrink();

    final theme = context.theme;
    final snapshot = state?.snapshotAtMs ?? meta?.snapshotAtMs ?? 0;
    final indexed = state?.indexedAtMs ?? meta?.indexedAtMs ?? 0;
    final total = state?.total ?? meta?.galleries ?? 0;
    final warnings = meta?.warnings ?? const <String>[];

    // 没有警告时不做成可点区域：一个点了什么都不会发生的区域，比不可点更让人
    // 困惑。（FTappable 的 onPress 是必填非空，所以这里显式分支而不是传 null。）
    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          _LiveIndicator(status: live),
          SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              snapshot > 0
                  ? '$total 本 · 元数据快照 ${formatRelative(snapshot)} · 索引 ${formatRelative(indexed)}'
                  : '$total 本 · 无数据库快照（标题来自目录名）· 索引 ${formatRelative(indexed)}',
              style: theme.typography.body.xs.copyWith(
                color: theme.colors.mutedForeground,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (warnings.isNotEmpty)
            Text(
              '${warnings.length} 条提示',
              style: theme.typography.body.xs.copyWith(
                color: theme.colors.primary,
              ),
            ),
        ],
      ),
    );

    return ColoredBox(
      color: theme.colors.muted,
      child: warnings.isEmpty
          ? content
          : FTappable(
              onPress: () => _showWarnings(context, warnings),
              child: content,
            ),
    );
  }

  void _showWarnings(BuildContext context, List<String> warnings) {
    showFDialog<void>(
      context: context,
      builder: (context, style, animation) => FDialog(
        builder: (context, style) => FDialogContent(
          title: '服务器提示',
          actions: [
            FButton(
              variant: FButtonVariant.outline,
              onPress: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
          children: [
            for (final warning in warnings)
              FDialogContent.line(context, '• $warning'),
          ],
        ),
      ),
    );
  }
}

/// 事件流是否连着。
///
/// 值得一个可见指示，而不是当一个沉默的后台功能：流断了库还是能用，只是不再
/// 自己更新；不知道这件事的用户会以为是服务器旧了，而不是实时更新关了。
class _LiveIndicator extends StatelessWidget {
  const _LiveIndicator({required this.status});

  final LiveStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final (color, icon, label) = switch (status) {
      LiveStatus.live => (theme.colors.primary, FLucideIcons.bolt, '实时'),
      LiveStatus.connecting => (
        theme.colors.mutedForeground,
        FLucideIcons.refreshCw,
        '连接中',
      ),
      LiveStatus.unavailable => (
        theme.colors.mutedForeground,
        FLucideIcons.bolt,
        '手动刷新',
      ),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: AppIcon.sm, color: color),
        SizedBox(width: AppSpacing.xs),
        Text(label, style: theme.typography.body.xs.copyWith(color: color)),
      ],
    );
  }
}
