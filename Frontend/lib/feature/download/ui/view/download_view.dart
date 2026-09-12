import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/confirm_dialog.dart';
import '../../../../common/widget/custom_empty_widget.dart';
import '../../../../common/widget/custom_error_widget.dart';
import '../../../../core/util/format_util.dart';
import '../../../../core/util/message_util.dart';
import '../../model/vo/downloaded_gallery_vo.dart';
import '../provider/download_provider.dart';
import '../widget/downloaded_gallery_tile.dart';

/// 下载管理页（底部导航的第三个目的地）：列出已下载的画廊、总占用、删除。
///
/// 这是一个纯「本机有什么」的页面，**不需要服务器**：标题、页数、占用都来自本地清单
/// 与目录，点进去直接是阅读器（本地优先，服务器不可达也能读）。只有封面会走网络，
/// 且失败也只是显示占位图——列表的可用性不依赖它。
class DownloadView extends ConsumerWidget {
  const DownloadView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = ref.watch(downloadSupportedProvider);
    final async = ref.watch(downloadListProvider);
    final items = async.value ?? const <DownloadedGalleryVo>[];

    return FScaffold(
      header: FHeader(
        title: const Text('下载'),
        suffixes: [
          FHeaderAction(
            icon: const Icon(FLucideIcons.refreshCw),
            semanticsTooltip: '刷新',
            onPress: () => ref.read(downloadListProvider.notifier).refresh(),
          ),
          FHeaderAction(
            icon: const Icon(FLucideIcons.trash2),
            semanticsTooltip: '删除全部下载',
            // 没有可删的东西时禁用：点一个不会有任何可见反应的按钮，比按钮灰着更
            // 让人怀疑应用坏了。
            onPress: supported && items.isNotEmpty
                ? () => _confirmDeleteAll(context, ref)
                : null,
          ),
        ],
      ),
      child: switch ((supported, async)) {
        (false, _) => const CustomEmptyWidget(
            icon: FLucideIcons.cloudOff,
            message: '此平台不支持本地下载',
            hint: '浏览器没有可以持久保存文件的目录，所以下载只在桌面与移动客户端可用。',
          ),
        // 有数据就先渲染数据，即使正在后台刷新：删除之后的刷新若把列表换成转圈，
        // 每一次删除都会闪一下白屏。
        (true, AsyncValue(value: final list?)) => list.isEmpty
            ? const CustomEmptyWidget(
                icon: FLucideIcons.folderDown,
                message: '还没有下载任何画廊',
                hint: '在画廊详情页点「下载」把整本存到本机，之后阅读就不必重复取图。',
              )
            : _Body(items: list),
        (true, AsyncError(:final error)) => CustomErrorWidget(
            error: error,
            onRetry: () => ref.invalidate(downloadListProvider),
          ),
        // 还没有任何值：首次加载中。
        (true, _) => const Center(child: FCircularProgress()),
      },
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.items});

  final List<DownloadedGalleryVo> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    final total = ref.watch(downloadTotalBytesProvider);

    return ListView(
      padding: theme.style.pagePadding,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '共 ${items.length} 本 · 占用 ${formatBytes(total)}',
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ),
            FButton(
              variant: FButtonVariant.outline,
              onPress: () => _confirmDeleteAll(context, ref),
              child: const Text('全部删除'),
            ),
          ],
        ),
        SizedBox(height: AppSpacing.md),
        for (final item in items) ...[
          DownloadedGalleryTile(
            item: item,
            // 直接进阅读器：详情页要问服务器，服务器不可达时那条路是死的。
            onOpen: () => context.go('/gallery/${item.gid}/read'),
            onDelete: () => _confirmDeleteOne(context, ref, item),
          ),
          SizedBox(height: AppSpacing.md),
        ],
        SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

/// 删除一本：先确认，再执行，最后按结果给反馈。
///
/// 删除是不可逆的（页文件删了就没了，重新下载要花流量），所以文案里必须带上占用与
/// 页数——「删除 12.3 MB / 726 页」比「确定删除吗」更能让人做出判断。
Future<void> _confirmDeleteOne(
  BuildContext context,
  WidgetRef ref,
  DownloadedGalleryVo item,
) async {
  final confirmed = await confirmDialog(
    context,
    title: '删除本地下载',
    message: '将删除《${item.displayTitle}》的 ${item.pageCount} 页'
        '（${formatBytes(item.bytes)}）。服务器上的原画廊不受影响。',
    // 按钮文案与列表里那个「删除」不同：弹窗里说清楚删的是**本机文件**，而不是
    // 服务端的画廊。
    confirmLabel: '删除本机文件',
  );
  if (!confirmed || !context.mounted) return;

  final result = await ref.read(downloadListProvider.notifier).delete(item.gid);
  if (!context.mounted) return;

  final error = result.error;
  showFToast(
    context: context,
    variant: error == null ? FToastVariant.primary : FToastVariant.destructive,
    title: Text(error == null ? '已删除' : '删除失败'),
    description: error == null ? null : Text(messageOf(error)),
  );
}

/// 删除全部。
Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref) async {
  final items = ref.read(downloadListProvider).value ?? const [];
  if (items.isEmpty) return;

  final total = ref.read(downloadTotalBytesProvider);
  final confirmed = await confirmDialog(
    context,
    title: '删除全部下载',
    message: '将删除 ${items.length} 本画廊的本地文件（共 ${formatBytes(total)}）。'
        '服务器上的原画廊不受影响。',
    confirmLabel: '全部删除',
  );
  if (!confirmed || !context.mounted) return;

  final result = await ref.read(downloadListProvider.notifier).deleteAll();
  if (!context.mounted) return;

  final error = result.error;
  showFToast(
    context: context,
    variant: error == null ? FToastVariant.primary : FToastVariant.destructive,
    title: Text(error == null ? '已清空下载' : '删除失败'),
    description: error == null ? null : Text(messageOf(error)),
  );
}
