import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/server_image_widget.dart';
import '../../../../core/service/reading_progress.dart';
import '../../../../core/util/format_util.dart';
import '../../enum/availability.dart';
import '../../model/vo/gallery_vo.dart';

/// 一个画廊磁贴。
///
/// 角标不是装饰：目录还没同步过来的画廊，看起来和坏掉的画廊一模一样；页数与
/// 元数据不符则意味着阅读时会跳页——两者都必须一眼能看出来。
class GalleryCard extends ConsumerWidget {
  const GalleryCard({super.key, required this.gallery, required this.onTap});

  final GalleryVo gallery;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    final progress = ref.watch(readingProgressProvider)[gallery.gid];

    return FCard(
      clipBehavior: Clip.antiAlias,
      child: FTappable(
        onPress: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Cover(gallery: gallery),
                  Positioned(
                    top: AppSpacing.xs,
                    left: AppSpacing.xs,
                    child: _CornerBadges(gallery: gallery),
                  ),
                  if (progress != null && gallery.pagesFound > 0)
                    Positioned(
                      right: AppSpacing.xs,
                      bottom: AppSpacing.xs,
                      child: _ProgressBadge(
                        page: progress.page,
                        total: gallery.pagesFound,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    gallery.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.body.xs.copyWith(
                      fontWeight: FontWeight.w500,
                      color: theme.colors.foreground,
                    ),
                  ),
                  SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      if (gallery.simpleLanguage.isNotEmpty) ...[
                        _MetaText(languageLabel(gallery.simpleLanguage)),
                        const _Dot(),
                      ],
                      _MetaText('${gallery.pagesFound} 页'),
                      if (gallery.rating > 0) ...[
                        const _Dot(),
                        Icon(
                          FLucideIcons.star,
                          size: AppIcon.sm * 0.6,
                          color: theme.colors.primary,
                        ),
                        _MetaText(gallery.rating.toStringAsFixed(1)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 封面，或一张说明「为什么没有封面」的占位。
///
/// 不可读的画廊不叠半透明遮罩，而是整块换成占位：遮罩在浅色和深色主题下需要
/// 两种前景色才能保证可读，而占位块两种主题下都清楚，且只用现有颜色 token。
class _Cover extends StatelessWidget {
  const _Cover({required this.gallery});

  final GalleryVo gallery;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    if (!gallery.isReadable) {
      return ColoredBox(
        color: theme.colors.muted,
        child: Center(
          child: Icon(
            gallery.onDisk ? FLucideIcons.imageOff : FLucideIcons.cloudOff,
            size: AppIcon.lg,
            color: theme.colors.mutedForeground,
          ),
        ),
      );
    }
    return ServerImage(
      // cover_url 是服务端相对路径，ServerImage 会解析成绝对地址。
      path: gallery.coverUrl,
      fit: BoxFit.cover,
      semanticLabel: gallery.displayTitle,
    );
  }
}

class _CornerBadges extends StatelessWidget {
  const _CornerBadges({required this.gallery});

  final GalleryVo gallery;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    if (gallery.availability == Availability.missing) {
      return _Badge(
        label: '未同步',
        background: theme.colors.error,
        foreground: theme.colors.errorForeground,
      );
    }
    if (gallery.hasSevereAnomaly || gallery.availability == Availability.degraded) {
      final missing = gallery.missingPageCount;
      return _Badge(
        label: missing != null ? '缺 $missing 页' : '异常',
        background: theme.colors.secondary,
        foreground: theme.colors.secondaryForeground,
      );
    }
    return const SizedBox.shrink();
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label,
        style: theme.typography.body.xs.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ProgressBadge extends StatelessWidget {
  const _ProgressBadge({required this.page, required this.total});

  final int page;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    // 阅读进度是 0 基存的；给人看要 1 基。
    final current = (page + 1).clamp(1, total);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: theme.colors.primary,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        '$current/$total',
        style: theme.typography.body.xs.copyWith(
          color: theme.colors.primaryForeground,
        ),
      ),
    );
  }
}

class _MetaText extends StatelessWidget {
  const _MetaText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Flexible(
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.typography.body.xs.copyWith(
          color: theme.colors.mutedForeground,
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Text(
        '·',
        style: theme.typography.body.xs.copyWith(
          color: theme.colors.mutedForeground,
        ),
      ),
    );
  }
}
