import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/custom_error_widget.dart';
import '../../../../core/service/local_prefs.dart';
import '../provider/reader_provider.dart';

/// 阅读器里的单页图片。
///
/// 三态齐全：加载中给出轻量占位而不是空白（空白看起来像渲染坏了），失败给出
/// 可重试的错误视图，成功才渲染图片。
///
/// 字节来自 [readerPageBytesProvider]，与预热共用同一份缓存——这正是「预热」
/// 有意义的原因。
class ReaderPageImage extends ConsumerWidget {
  const ReaderPageImage({
    super.key,
    required this.gid,
    required this.position,
    required this.fit,
    this.onTap,
  });

  final int gid;

  /// 页在列表里的位置（从 0 开始），不是文件编号。
  final int position;

  final ReaderFit fit;

  /// 点按回调，用来显示/隐藏控制层。
  ///
  /// 挂在每一页上而不是包住整个 `PageView`：外层 `GestureDetector` 的 tap 会在
  /// 手势竞技场里输给可滚动组件的拖拽识别器，点按根本不会触发；页面内部没有
  /// 竞争者，tap 才能稳定命中。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (gid: gid, position: position);
    final bytes = ref.watch(readerPageBytesProvider(key));

    return ColoredBox(
      color: context.theme.colors.background,
      child: GestureDetector(
        // 整页都可点，包括图片与视口之间的空白。
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: bytes.when(
          loading: () => const _PagePlaceholder(),
          error: (error, _) => CustomErrorWidget(
            error: error,
            retryLabel: '重新加载',
            onRetry: () => ref.invalidate(readerPageBytesProvider(key)),
          ),
          data: (data) => _PageImage(bytes: data, fit: fit, position: position),
        ),
      ),
    );
  }
}

/// 已就绪的图片本体。
///
/// 缩放只在「原始尺寸」下开启：另外两种模式画面已经适配视口，再套一层可缩放层
/// 只会把翻页手势和缩放手势搅在一起。
class _PageImage extends StatefulWidget {
  const _PageImage({
    required this.bytes,
    required this.fit,
    required this.position,
  });

  final Uint8List bytes;
  final ReaderFit fit;
  final int position;

  @override
  State<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<_PageImage> {
  final _zoom = TransformationController();

  @override
  void didUpdateWidget(covariant _PageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了页就把缩放重置，否则上一页留下的位移会把新页推到视口外。
    if (oldWidget.position != widget.position || oldWidget.fit != widget.fit) {
      _zoom.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 解码失败说明拿到的字节不是当前平台能渲染的图片，值得说出来而不是显示
    // 一个破图标。
    Widget errorBuilder(BuildContext context, Object error) =>
        CustomErrorWidget(error: error);

    final natural = Image.memory(
      widget.bytes,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) => errorBuilder(context, error),
    );

    return switch (widget.fit) {
      // 整页铺满：完整显示，长图会留白。
      ReaderFit.contain => Center(
          child: Image.memory(
            widget.bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) =>
                errorBuilder(context, error),
          ),
        ),
      // 按宽度铺满：高度溢出时由纵向滚动查看。
      ReaderFit.width => Image.memory(
          widget.bytes,
          fit: BoxFit.fitWidth,
          width: double.infinity,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) => errorBuilder(context, error),
        ),
      // 原始尺寸：不缩放，交给 InteractiveViewer 平移查看。
      ReaderFit.original => InteractiveViewer(
          transformationController: _zoom,
          // constrained 为 false 才能让图片保持自然尺寸；否则会被压回视口大
          // 小，「原始尺寸」就名存实亡了。
          constrained: false,
          minScale: 0.5,
          maxScale: 4,
          child: natural,
        ),
    };
  }
}

/// 图片加载中的占位。
///
/// 用主题里的静音色而不是纯黑：深色主题下纯黑会让整屏看起来像卡死。
class _PagePlaceholder extends StatelessWidget {
  const _PagePlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return ColoredBox(
      color: theme.colors.muted,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FCircularProgress(),
            SizedBox(height: AppSpacing.md),
            Text(
              '正在载入',
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
