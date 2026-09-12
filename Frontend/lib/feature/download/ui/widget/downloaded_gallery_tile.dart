import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/server_image_widget.dart';
import '../../../../core/util/format_util.dart';
import '../../enum/download_status.dart';
import '../../model/vo/downloaded_gallery_vo.dart';

/// 下载管理列表里的一项。
///
/// 卡片主体可点，**直接进阅读器**而不是画廊详情页：这一页列的是本机已有的东西，
/// 点它的动机是「接着读」，而详情页要问服务器——服务器不可达时那条路是死的，
/// 断网阅读也就无从谈起。
///
/// 删除按钮在可点区域**之外**：把删除塞进可点区域会让「点卡片阅读」和「点删除」
/// 共用一个手势区，用户点歪一次就删了一本。
class DownloadedGalleryTile extends StatelessWidget {
  const DownloadedGalleryTile({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onDelete,
  });

  final DownloadedGalleryVo item;

  /// 从本机打开阅读器。
  final VoidCallback onOpen;

  /// 请求删除这一本（二次确认由调用方负责）。
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return FCard(
      child: Padding(
        padding: theme.style.pagePadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: FTappable(
                onPress: onOpen,
                child: Row(
                  children: [
                    _Cover(path: item.coverPath, label: item.displayTitle),
                    SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.typography.body.md.copyWith(
                              color: theme.colors.foreground,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: AppSpacing.xs),
                          Text(
                            '${item.pageCount} 页 · ${formatBytes(item.bytes)} · '
                            '${formatDate(item.downloadedAtMs)}',
                            style: theme.typography.body.sm.copyWith(
                              color: theme.colors.mutedForeground,
                            ),
                          ),
                          SizedBox(height: AppSpacing.xs),
                          Text(
                            '点一下从本机阅读',
                            style: theme.typography.body.xs.copyWith(
                              color: theme.colors.mutedForeground,
                            ),
                          ),
                          if (!item.isComplete) ...[
                            SizedBox(height: AppSpacing.xs),
                            Text(
                              '${DownloadStatus.partial.label}：进详情页可以接着下',
                              style: theme.typography.body.xs.copyWith(
                                color: theme.colors.error,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: AppSpacing.sm),
            FButton(
              variant: FButtonVariant.outline,
              onPress: onDelete,
              prefix: const Icon(FLucideIcons.trash2, size: AppIcon.sm),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表里的封面。
///
/// 走 [ServerImage] 而不是本地文件：本地只有页图，没有存封面（存了也只是多占一份
/// 空间，而封面在服务端通常是缩略图，代价很小）。服务不可达时它显示占位图，
/// 不影响删除与列表本身。
class _Cover extends StatelessWidget {
  const _Cover({required this.path, required this.label});

  final String path;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final size = theme.style.sizes.field.md;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox(
        width: size,
        height: size * 1.33,
        child: path.isEmpty
            ? ColoredBox(
                color: theme.colors.muted,
                child: Icon(
                  FLucideIcons.imageOff,
                  size: AppIcon.sm,
                  color: theme.colors.mutedForeground,
                ),
              )
            : ServerImage(path: path, semanticLabel: label),
      ),
    );
  }
}
