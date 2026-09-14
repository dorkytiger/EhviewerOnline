import 'dart:async';

import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/custom_error_widget.dart';
import '../../../../core/service/local_prefs.dart';
import '../../../../core/service/reading_progress.dart';
import '../../../library/model/vo/gallery_detail_vo.dart';
import '../../service/reader_service.dart';
import '../provider/reader_provider.dart';
import '../widget/reader_page_image.dart';

/// 全屏阅读器。
///
/// 要处理好的三件事：
///
///  * **内存**：几百页的画廊不可能全塞进内存。分页模式只让当前页与邻居存活，
///    纵向模式用基于视口的缓存范围，预热半径由 `AppConfig.readerPreloadRadius`
///    统一决定（见 [ReaderService.preloadWindow]），滑出窗口的字节会被回收。
///  * **缺页**：服务端列出的页可能少于元数据声明的页数，文件编号因此会与位置
///    不一致。一律按**位置**寻址，绝不假设「编号等于位置」。
///  * **进度**：每次翻页都存本地。后端按设计是只读的，不往同步目录里写任何
///    东西——那是「另一个写入者」，会和 Syncthing 打架。
class ReaderView extends ConsumerStatefulWidget {
  const ReaderView({super.key, required this.gid, this.initialPage = 0});

  final int gid;

  /// 打开时的起始页位置。详情页的「继续阅读」会传它；默认 0。
  final int initialPage;

  @override
  ConsumerState<ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends ConsumerState<ReaderView> {
  late final PageController _pages;

  /// 起始位置在首帧就定下来：详情还没到，此时 provider 里是空状态。
  late int _requestedPage;

  /// 最近一次写进本地的位置，避免同一个位置重复落盘。
  int? _savedPosition;

  /// 是否已经用 [_requestedPage] 定位过一次。
  ///
  /// 详情会因 SSE 索引变更而重建，那时必须保留用户当前页；只有第一次绑定才
  /// 用起始页覆盖，否则每次索引刷新都会把人弹回打开时的那一页。
  bool _positioned = false;

  /// 控制层（页头 + 底部控制条）是否可见。
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    // 路由没给页码时接着上次读：从详情页进入与退到详情页再回来都要能续读。
    final saved = ref.read(readingProgressProvider.notifier).pageFor(widget.gid);
    _requestedPage = widget.initialPage > 0 ? widget.initialPage : (saved ?? 0);
    _pages = PageController(initialPage: _requestedPage);

    // 总页数只能在详情到达后绑定，而首帧就需要它（否则第 5 页会被当成第 0 页
    // 渲染）。`listenManual` 支持 `fireImmediately`，且它不依赖 build 阶段，
    // 所以在 initState 里完成首次绑定；`ref.listen` 没有这个开关。
    ref.listenManual(
      readerDetailProvider(widget.gid),
      (previous, next) {
        final value = next.value;
        if (value == null) return;
        ref.read(readerPositionProvider.notifier).bindTotal(
              value.pagesDetail.length,
              initialPosition: _positioned ? null : _requestedPage,
            );
        _positioned = true;
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(readerDetailProvider(widget.gid));
    final position = ref.watch(readerPositionProvider);
    final prefs = ref.watch(localPrefsProvider);

    // 位置只由 viewmodel 提供：翻页与跳页都先改状态，再由这里统一落盘。
    ref.listen(readerPositionProvider, (previous, next) {
      if (previous?.pageIndex == next.pageIndex) return;
      _saveProgress(next.clampedIndex);
    });

    final ready = position.hasPages ? position.clampedIndex : _requestedPage;

    return detail.when(
      loading: () => FScaffold(
        header: _header('读取中'),
        child: const _ReadingPlaceholder(),
      ),
      error: (error, _) => FScaffold(
        header: _header('阅读失败'),
        child: CustomErrorWidget(
          error: error,
          onRetry: () => ref.invalidate(readerDetailProvider(widget.gid)),
        ),
      ),
      data: (value) {
        final total = value.pagesDetail.length;
        if (total == 0) {
          return FScaffold(
            header: _header(value.gallery.displayTitle),
            child: const _NoPagesView(),
          );
        }

        final current = ready.clamp(0, total - 1);
        final gap = ReaderService.gapAt(value, current);
        _saveProgress(current);

        return FScaffold(
              header: _chromeVisible ? _header(_title(value, current, total), prefs: prefs) : null,
          footer: _chromeVisible
              ? _ControlBar(
                  current: current,
                  total: total,
                  onJump: _jumpTo,
                  onPrevious:
                      position.canGoBack ? () => _jumpTo(current - 1) : null,
                  onNext: position.canGoForward
                      ? () => _jumpTo(current + 1)
                      : null,
                )
              : null,
          child: Stack(
            children: [
              Positioned.fill(
                // 预热窗口独立于可见页：它在后台把邻居的字节拿进缓存。
                child: ReaderPreload(gid: widget.gid),
              ),
              Positioned.fill(
                // 点按显示/隐藏控制层挂在每一页上，而不是包住整个 PageView：
                // 外层 GestureDetector 的 tap 会在手势竞技场里输给可滚动组件的
                // 拖拽识别器，点按根本不会触发。
                child: prefs.readerDirection == ReaderDirection.vertical
                    ? _VerticalReader(
                        key: ValueKey('vertical-${widget.gid}'),
                        gid: widget.gid,
                        total: total,
                        position: current,
                        fit: prefs.fitMode,
                        onPositionChanged: _onPageChanged,
                        onTap: _toggleChrome,
                      )
                    : _PagedReader(
                        key: ValueKey('paged-${widget.gid}'),
                        gid: widget.gid,
                        total: total,
                        controller: _pages,
                        fit: prefs.fitMode,
                        reverse:
                            prefs.readerDirection == ReaderDirection.rightToLeft,
                        onPageChanged: _onPageChanged,
                        onTap: _toggleChrome,
                      ),
              ),
              // 缺页要明说：静默显示一张编号对不上的图，看起来就是渲染出了
              // bug，而且用户无从知道中间少了一页。
              if (gap != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _GapBanner(gap: gap),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 页头。加载中与失败态没有偏好可切换，所以 [prefs] 为空。
  Widget _header(String title, {LocalPrefs? prefs}) {
    return FHeader.nested(
      title: Text(title),
      prefixes: [
        FHeaderAction(
          icon: const Icon(FLucideIcons.arrowLeft),
          semanticsLabel: '返回详情',
          onPress: _back,
        ),
      ],
      suffixes: [
        if (prefs != null) ...[
          FHeaderAction(
            icon: Icon(_directionIcon(prefs.readerDirection)),
            semanticsLabel: prefs.readerDirection.label,
            semanticsTooltip: prefs.readerDirection.description,
            onPress: () => _cycleDirection(prefs),
          ),
          FHeaderAction(
            icon: Icon(_fitIcon(prefs.fitMode)),
            semanticsLabel: prefs.fitMode.label,
            semanticsTooltip: prefs.fitMode.description,
            onPress: () => _cycleFit(prefs),
          ),
        ],
      ],
    );
  }

  /// 标题里的页码与「声明页数」提示。
  String _title(GalleryDetailVo detail, int current, int total) {
    final declared = detail.gallery.pagesExpected;
    if (declared <= 0 || declared == total) return '${current + 1} / $total';
    return '${current + 1} / $total（声明 $declared）';
  }

  void _back() {
    final router = GoRouter.of(context);
    // 直接从详情页的「继续阅读」深链进来时栈里可能没有上一页，退回图库详情
    // 而不是把用户留在空栈里。
    if (router.canPop()) {
      router.pop();
    } else {
      router.go('/gallery/${widget.gid}');
    }
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  void _onPageChanged(int position) {
    ref.read(readerPositionProvider.notifier).goTo(position);
  }

  /// 记录进度。
  ///
  /// 写的是**位置**而不是文件编号：位置才是恢复阅读时能直接用的值。
  void _saveProgress(int position) {
    if (position == _savedPosition) return;
    _savedPosition = position;
    // 写本地偏好失败不该打断阅读；控制器内部先更新内存态，持久化失败只影响
    // 下次冷启动的续读位置。
    unawaited(
      ref.read(readingProgressProvider.notifier).save(widget.gid, position),
    );
  }

  void _jumpTo(int position) {
    if (_pages.hasClients) {
      _pages.jumpToPage(position);
      return;
    }
    // 纵向模式没有 PageController：位置变化后 _VerticalReader 自己会滚过去。
    _onPageChanged(position);
  }

  void _cycleDirection(LocalPrefs prefs) {
    final values = ReaderDirection.values;
    final next =
        values[(values.indexOf(prefs.readerDirection) + 1) % values.length];
    ref.read(localPrefsProvider.notifier).setReaderDirection(next);
  }

  void _cycleFit(LocalPrefs prefs) {
    final values = ReaderFit.values;
    final next = values[(values.indexOf(prefs.fitMode) + 1) % values.length];
    ref.read(localPrefsProvider.notifier).setFitMode(next);
  }

  static IconData _directionIcon(ReaderDirection direction) =>
      switch (direction) {
        ReaderDirection.leftToRight => FLucideIcons.arrowLeftRight,
        ReaderDirection.rightToLeft => FLucideIcons.arrowRightLeft,
        ReaderDirection.vertical => FLucideIcons.arrowUpDown,
      };

  static IconData _fitIcon(ReaderFit fit) => switch (fit) {
        ReaderFit.contain => FLucideIcons.maximize,
        ReaderFit.width => FLucideIcons.moveHorizontal,
        ReaderFit.original => FLucideIcons.moveVertical,
      };
}

/// 横向翻页：一次一页。
class _PagedReader extends StatelessWidget {
  const _PagedReader({
    super.key,
    required this.gid,
    required this.total,
    required this.controller,
    required this.fit,
    required this.reverse,
    required this.onPageChanged,
    required this.onTap,
  });

  final int gid;
  final int total;
  final PageController controller;
  final ReaderFit fit;
  final bool reverse;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: controller,
      reverse: reverse,
      onPageChanged: onPageChanged,
      // 让 PageView 在当前页两侧各多留一屏，配合页缓存把邻居图片的字节提前
      // 拿回来——翻页看起来是瞬时的，靠的就是这个。
      allowImplicitScrolling: true,
      itemCount: total,
      itemBuilder: (context, index) => ReaderPageImage(
        gid: gid,
        position: index,
        fit: fit,
        onTap: onTap,
      ),
    );
  }
}

/// 纵向滚动：适合长条与 webtoon 式页面。
///
/// 每页占满一屏，于是「位置 = 滚动偏移 ÷ 视口高度」，不需要等图片解码出真实
/// 高度也能定位；代价是短页下方留白，这是刻意的取舍。
class _VerticalReader extends StatefulWidget {
  const _VerticalReader({
    super.key,
    required this.gid,
    required this.total,
    required this.position,
    required this.fit,
    required this.onPositionChanged,
    required this.onTap,
  });

  final int gid;
  final int total;
  final int position;
  final ReaderFit fit;
  final ValueChanged<int> onPositionChanged;
  final VoidCallback onTap;

  @override
  State<_VerticalReader> createState() => _VerticalReaderState();
}

class _VerticalReaderState extends State<_VerticalReader> {
  late final ScrollController _scroll;

  /// 最近一次上报的位置；避免滚动过程中反复上报同一个值。
  late int _reported = widget.position;

  /// 是否正处于「按外部位置滚过去」的过程中。
  ///
  /// 滚动监听必须区分「用户滑的」与「程序跳的」，否则程序跳转会再触发一次
  /// 位置变更，来回抖动。
  bool _syncing = false;

  /// 待处理的外部定位目标；只在「位置来源不是自己的滚动」时才设置。
  int? _pendingTarget;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
    _scroll.addListener(_onScroll);
    if (widget.position > 0) _pendingTarget = widget.position;
    // 首次布局还没有视口尺寸，定位要等一帧。
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyPending());
  }

  @override
  void didUpdateWidget(covariant _VerticalReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 自己滚出来的位置变化会原样回传（`_reported == widget.position`），这里
    // 必须跳过，否则每次上报都触发一次 jumpTo，把正在进行的平滑滚动钉死在
    // 页边界上。只有外部（控制条、上一页/下一页）改的位置才需要滚过去。
    if (oldWidget.position != widget.position &&
        widget.position != _reported) {
      _pendingTarget = widget.position;
      _applyPending();
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// 每页一屏高时，第 n 页的偏移就是 n 个视口。
  double _offsetFor(int index) => _scroll.position.viewportDimension * index;

  void _applyPending() {
    final target = _pendingTarget;
    if (target == null || !_scroll.hasClients) return;
    _pendingTarget = null;

    final offset =
        _offsetFor(target).clamp(0.0, _scroll.position.maxScrollExtent);
    _reported = target;
    _syncing = true;
    _scroll.jumpTo(offset);
    _syncing = false;
  }

  void _onScroll() {
    if (_syncing || !_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    if (viewport <= 0) return;
    final index =
        (_scroll.position.pixels / viewport).round().clamp(0, widget.total - 1);
    if (index == _reported) return;
    _reported = index;
    widget.onPositionChanged(index);
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scroll,
      itemCount: widget.total,
      // 基于视口的缓存范围：N 个视口 = 前后各 N 页，与分页模式的预热半径
      // 同一口径。
      scrollCacheExtent: ScrollCacheExtent.viewport(
        AppConfig.readerPreloadRadius.toDouble(),
      ),
      itemBuilder: (context, index) => SizedBox(
        height: MediaQuery.sizeOf(context).height,
        child: ReaderPageImage(
          gid: widget.gid,
          position: index,
          fit: widget.fit,
          onTap: widget.onTap,
        ),
      ),
    );
  }
}

/// 预热窗口的持有者。
///
/// 它自己不显示任何东西，存在的唯一理由是**给预热 provider 一个 watcher**：
/// 没有 watcher，`autoDispose` 会在下一帧把刚预热的字节回收掉，预热就白做了。
/// 窗口移动时顺手把滑出窗口的页 `invalidate`，常驻内存的图片数量因此有上界，
/// 而不是随「读过多少页」增长。
class ReaderPreload extends ConsumerStatefulWidget {
  const ReaderPreload({super.key, required this.gid});

  final int gid;

  @override
  ConsumerState<ReaderPreload> createState() => _ReaderPreloadState();
}

class _ReaderPreloadState extends ConsumerState<ReaderPreload> {
  @override
  Widget build(BuildContext context) {
    final window = ref.watch(readerPreloadWindowProvider);
    for (final position in window) {
      // 只 watch 不 await：字节留在 provider 缓存里，显示时直接命中。
      //
      // 这里的 watch 也是**回收机制本身**：滑出窗口的页会在这里失去最后一个
      // 监听者，autoDispose 于是把它丢掉，常驻图片数量与预热半径成正比。
      //
      // 不要在 didUpdateWidget 里手动 invalidate 来回收：那个回调发生在构建
      // 阶段，会让 Riverpod 在 build 中标记 provider 失效并抛
      // `setState() or markNeedsBuild() called during build`。
      ref.watch(readerPageBytesProvider((gid: widget.gid, position: position)));
    }
    return const SizedBox.shrink();
  }
}

/// 底部控制条：滑块定位 + 上一页/下一页 + 当前页码。
class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.current,
    required this.total,
    required this.onJump,
    required this.onPrevious,
    required this.onNext,
  });

  final int current;
  final int total;
  final ValueChanged<int> onJump;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final max = (total - 1).toDouble();
    final usable = max > 0;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          children: [
            // 这里必须用通用按钮，**不能**用 FHeaderAction：后者断言自己必须住在
            // FHeader 里（它要从 FHeaderData 取样式与尺寸），放进普通 Row 会先
            // 触发断言、再因为没有 header 约束而撑出天文数字的溢出。控制条不是
            // 页头，用一个带 ghost 样式的按钮才是它该有的样子。
            FButton(
              variant: FButtonVariant.ghost,
              onPress: onPrevious,
              child: const Icon(FLucideIcons.chevronLeft),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                child: FSlider(
                  enabled: usable,
                  control: FSliderControl.liftedContinuous(
                    value: FSliderValue(max: usable ? current / max : 0),
                    onChange: (value) => onJump(
                      (value.max * max).round().clamp(0, total - 1),
                    ),
                  ),
                  // 页数不太多时给刻度，拖动会停在整页附近；几百条刻度既看不清
                  // 也拖不动，所以超过阈值就不画。
                  marks: [
                    if (usable && total <= _maxMarks)
                      for (var i = 0; i < total; i++)
                        FSliderMark(value: i / max, tick: true),
                  ],
                ),
              ),
            ),
            FButton(
              variant: FButtonVariant.ghost,
              onPress: onNext,
              child: const Icon(FLucideIcons.chevronRight),
            ),
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.xs),
              child: Text(
                '${current + 1}/$total',
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 页数超过这个值就不再画刻度。
const int _maxMarks = 20;

/// 详情尚在路上的占位。
class _ReadingPlaceholder extends StatelessWidget {
  const _ReadingPlaceholder();

  @override
  Widget build(BuildContext context) => const Center(child: FCircularProgress());
}

/// 画廊一页都没有时的空态。
class _NoPagesView extends StatelessWidget {
  const _NoPagesView();

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Center(
      child: Padding(
        padding: theme.style.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FLucideIcons.imageOff,
              size: AppIcon.lg,
              color: theme.colors.mutedForeground,
            ),
            SizedBox(height: AppSpacing.md),
            Text('该画廊没有可用页面', style: theme.typography.body.lg),
            SizedBox(height: AppSpacing.xs),
            Text(
              '服务端没有在磁盘上找到这个画廊的图片',
              textAlign: TextAlign.center,
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 缺页提示条。
class _GapBanner extends StatelessWidget {
  const _GapBanner({required this.gap});

  final ReaderGap gap;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return ColoredBox(
      color: theme.colors.muted,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              FLucideIcons.info,
              size: AppIcon.sm,
              color: theme.colors.mutedForeground,
            ),
            SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '第 ${gap.displayNumber} 张显示的是文件编号 ${gap.fileNumber} 的页面'
                '（本地缺页，元数据的页码不连续）',
                style: theme.typography.body.xs.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
