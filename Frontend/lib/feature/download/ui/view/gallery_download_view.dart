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
import '../../../library/model/vo/gallery_detail_vo.dart';
import '../../datasource/runtime/download_task_runtime.dart';
import '../../enum/download_phase.dart';
import '../../model/dto/download_request_dto.dart';
import '../../model/state/download_task_state.dart';
import '../../model/vo/downloaded_gallery_vo.dart';
import '../provider/download_detail_provider.dart';
import '../provider/download_provider.dart';

/// 单本画廊的下载页：预计大小、开始/取消/继续、删除本地副本。
///
/// 单独成页而不是把按钮塞进画廊详情页，是为了让「下载」这件事只有一个入口和一份
/// 状态：进度、取消、失败重试、删除都在这里，用户不需要在两个页面之间对照同一件事
/// 的两种说法。
///
/// 打开这一页**需要服务器**（页列表从详情接口来），但下载完成后就不需要了：
/// 阅读器在服务器不可达时会用本地清单重建页列表（见 `DownloadService.localDetail`），
/// 所以下载过的画廊可以断网继续读。下载本身当然还是要连服务器——页图得从哪儿来。
class GalleryDownloadView extends ConsumerWidget {
  const GalleryDownloadView({super.key, required this.gid});

  final int gid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = ref.watch(downloadSupportedProvider);
    final detail = ref.watch(downloadDetailProvider(gid));
    final task = ref.watch(downloadTaskProvider);

    // 下载一结束就刷新列表：管理页与详情页的「已下载」状态都从它推导，不刷新就会
    // 显示「还没下载」，而下一次进管理页又突然出现。
    ref.listen(downloadTaskProvider, (previous, next) {
      if (!next.belongsTo(gid) || next.phase == DownloadPhase.downloading) return;
      // 成功、取消、失败都会改动磁盘：成功写出清单，取消与失败留下部分副本。
      ref.invalidate(downloadListProvider);
    });

    return FScaffold(
      header: FHeader.nested(
        title: Text(detail.value?.gallery.displayTitle ?? '下载 #$gid'),
        prefixes: [
          FHeaderAction(
            icon: const Icon(FLucideIcons.arrowLeft),
            onPress: () => context.canPop() ? context.pop() : context.go('/'),
          ),
        ],
      ),
      child: !supported
          ? const CustomEmptyWidget(
              icon: FLucideIcons.cloudOff,
              message: '此平台不支持本地下载',
              hint: '浏览器没有可以持久保存文件的目录，所以下载只在桌面与移动客户端可用。',
            )
          : detail.when(
              loading: () => const Center(child: FCircularProgress()),
              error: (error, _) => CustomErrorWidget(
                error: error,
                onRetry: () => ref.invalidate(downloadDetailProvider(gid)),
              ),
              data: (value) => _Body(detail: value, task: task),
            ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.detail, required this.task});

  final GalleryDetailVo detail;
  final DownloadTaskState task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    final gid = detail.gallery.gid;
    final downloaded = ref.watch(downloadedGalleryProvider(gid));
    final running = task.belongsTo(gid) && task.isRunning;

    return ListView(
      padding: theme.style.pagePadding,
      children: [
        _Summary(detail: detail, downloaded: downloaded),
        SizedBox(height: AppSpacing.lg),
        if (task.belongsTo(gid)) ...[
          _TaskPanel(
            task: task,
            onDismiss: () => ref.read(downloadTaskProvider.notifier).dismiss(),
          ),
          SizedBox(height: AppSpacing.lg),
        ],
        // 用 Wrap 而不是 Row：窄屏上「下载到本机」+「删除本地下载」会超过一行，
        // Row 会溢出，Wrap 换行。
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.sm,
          children: [
            if (running)
              FButton(
                variant: FButtonVariant.outline,
                onPress: () => ref.read(downloadTaskProvider.notifier).cancel(),
                prefix: const Icon(FLucideIcons.x, size: AppIcon.sm),
                child: const Text('取消下载'),
              )
            else
              FButton(
                // 页列表还没到就不可能开始，所以这里只受「是否正在下载」影响。
                onPress: () => _start(context, ref, detail),
                prefix: const Icon(FLucideIcons.download, size: AppIcon.sm),
                child: Text(_startLabel(downloaded)),
              ),
            if (downloaded != null)
              FButton(
                variant: FButtonVariant.destructive,
                onPress: () => _delete(context, ref, downloaded),
                prefix: const Icon(FLucideIcons.trash2, size: AppIcon.sm),
                child: const Text('删除本地下载'),
              ),
          ],
        ),
        SizedBox(height: AppSpacing.lg),
        Text(
          '已下载的页在阅读时优先从本机读取；只有本机没有、或服务端的图已经变过'
          '（文件名或修改时间对不上）才会回源。整本下完之后，即使服务器连不上也能'
          '从「下载」页直接阅读。删除本地下载不影响服务器上的画廊。',
          style: theme.typography.body.xs.copyWith(
            color: theme.colors.mutedForeground,
          ),
        ),
        SizedBox(height: AppSpacing.xxl),
      ],
    );
  }

  /// 按钮文案说清这次点击会发生什么：已经完整下载过就不再是「下载」。
  String _startLabel(DownloadedGalleryVo? downloaded) {
    if (downloaded == null) return '下载到本机';
    return downloaded.isComplete ? '重新下载' : '继续下载';
  }

  Future<void> _start(
    BuildContext context,
    WidgetRef ref,
    GalleryDetailVo detail,
  ) async {
    final result = await ref
        .read(downloadTaskProvider.notifier)
        .start(DownloadRequestDto.fromGalleryDetail(detail));
    if (!context.mounted) return;

    final error = result.error;
    if (error == null) return;
    // 启动就被拒绝（已有任务在跑、平台不支持）必须说出来，否则按钮看起来没反应。
    showFToast(
      context: context,
      variant: FToastVariant.destructive,
      title: const Text('无法开始下载'),
      description: Text(messageOf(error)),
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    DownloadedGalleryVo downloaded,
  ) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除本地下载',
      message: '将删除本机保存的 ${downloaded.pageCount} 页'
          '（${formatBytes(downloaded.bytes)}）。服务器上的原画廊不受影响。',
      confirmLabel: '删除',
    );
    if (!confirmed || !context.mounted) return;

    final result = await ref.read(downloadListProvider.notifier).delete(
          downloaded.gid,
        );
    if (!context.mounted) return;

    final error = result.error;
    showFToast(
      context: context,
      variant: error == null ? FToastVariant.primary : FToastVariant.destructive,
      title: Text(error == null ? '已删除本地下载' : '删除失败'),
      description: error == null ? null : Text(messageOf(error)),
    );
  }
}

/// 画廊概况 + 本机已有的那一份。
class _Summary extends StatelessWidget {
  const _Summary({required this.detail, required this.downloaded});

  final GalleryDetailVo detail;
  final DownloadedGalleryVo? downloaded;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final gallery = detail.gallery;
    // 逐页大小的合计。服务端给的 size 是**文件大小**，与真实传输量会有出入（压缩、
    // 分块），所以这是「预计」而不是承诺。
    final expectedBytes =
        detail.pagesDetail.fold<int>(0, (sum, page) => sum + page.size);
    final saved = downloaded;

    return FCard(
      child: Padding(
        padding: theme.style.pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本机状态',
              style: theme.typography.body.lg.copyWith(
                color: theme.colors.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: AppSpacing.md),
            _KeyValue(
              label: '服务端页数',
              value: '${detail.pagesDetail.length} 页',
            ),
            _KeyValue(
              label: '预计大小',
              value: expectedBytes > 0 ? formatBytes(expectedBytes) : '未知',
            ),
            if (saved == null)
              const _KeyValue(label: '本机副本', value: '无')
            else ...[
              _KeyValue(
                label: '本机副本',
                value: '${saved.statusLabel} · ${saved.pageCount} 页 · '
                    '${formatBytes(saved.bytes)}',
              ),
              _KeyValue(
                label: '下载时间',
                value: formatDateTime(saved.downloadedAtMs),
              ),
            ],
            if (gallery.pagesFound != detail.pagesDetail.length)
              _KeyValue(
                label: '注意',
                value: '服务端可用 ${detail.pagesDetail.length} 页，'
                    '元数据声明 ${gallery.pagesFound} 页，下载的是前者',
              ),
          ],
        ),
      ),
    );
  }
}

/// 进行中的进度或上一次的结局。
///
/// 结束之后可以收起：结果本身已经写在下面的「本机副本」里，留下一条陈旧的「已取消」
/// 只会在下次进来时让人以为又发生了一次。
class _TaskPanel extends StatelessWidget {
  const _TaskPanel({required this.task, required this.onDismiss});

  final DownloadTaskState task;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final progress = task.progress;

    return FCard(
      child: Padding(
        padding: theme.style.pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.label,
                    style: theme.typography.body.md.copyWith(
                      color: task.phase == DownloadPhase.failed
                          ? theme.colors.error
                          : theme.colors.foreground,
                    ),
                  ),
                ),
                if (!task.isRunning)
                  FButton(
                    variant: FButtonVariant.ghost,
                    onPress: onDismiss,
                    child: const Text('收起'),
                  ),
              ],
            ),
            SizedBox(height: AppSpacing.md),
            if (progress == null)
              const FProgress(semanticsLabel: '下载进度')
            else
              FDeterminateProgress(value: progress, semanticsLabel: '下载进度'),
            if (task.phase == DownloadPhase.failed) ...[
              SizedBox(height: AppSpacing.sm),
              Text(
                '已下载的页都保留着，再点一次「继续下载」会从断点接着下。',
                style: theme.typography.body.xs.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 「标签：值」里标签列的宽度。定宽而不是让它自适应：多行的值才会左边对齐，
/// 否则每行的冒号落在不同位置，一列信息看起来像三列表格。
const double _labelWidth = 96;

/// 一行「标签：值」。
class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _labelWidth,
            child: Text(
              label,
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
