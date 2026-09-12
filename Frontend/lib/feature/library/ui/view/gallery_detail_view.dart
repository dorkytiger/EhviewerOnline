import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/custom_error_widget.dart';
import '../../../../common/widget/server_image_widget.dart';
import '../../../../core/service/reading_progress.dart';
import '../../../../core/util/format_util.dart';
import '../../enum/availability.dart';
import '../../enum/tag_dimension.dart';
import '../../enum/title_source.dart';
import '../../model/vo/gallery_detail_vo.dart';
import '../../model/vo/gallery_vo.dart';
import '../provider/gallery_detail_provider.dart';

/// 单个画廊：封面、元数据、异常与页面列表。
class GalleryDetailView extends ConsumerWidget {
  const GalleryDetailView({super.key, required this.gid});

  final int gid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(galleryDetailProvider(gid));

    return FScaffold(
      header: FHeader.nested(
        title: Text(async.value?.gallery.displayTitle ?? '画廊 #$gid'),
        prefixes: [
          FHeaderAction(
            icon: const Icon(FLucideIcons.arrowLeft),
            onPress: () =>
                context.canPop() ? context.pop() : context.go('/'),
          ),
        ],
      ),
      child: async.when(
        loading: () => const Center(child: FCircularProgress()),
        error: (error, _) => CustomErrorWidget(
          error: error,
          onRetry: () => ref.invalidate(galleryDetailProvider(gid)),
        ),
        data: (detail) => _DetailBody(detail: detail),
      ),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.detail});

  final GalleryDetailVo detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gallery = detail.gallery;
    final theme = context.theme;
    final progress = ref.watch(readingProgressProvider)[gallery.gid];

    return LayoutBuilder(
      builder: (context, constraints) {
        // 720 以上并排，以下堆叠：手机拿到的是封面条 + 文字，桌面窗口拿到的是
        // 海报式布局。
        final wide = constraints.maxWidth >= _wideBreakpoint;
        final coverWidth = wide ? _coverWide : _coverNarrow;

        return SingleChildScrollView(
          padding: EdgeInsets.all(AppSpacing.xl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: coverWidth, child: _Cover(gallery: gallery)),
                      SizedBox(width: AppSpacing.xl),
                      Expanded(child: _Header(gallery: gallery, detail: detail)),
                    ],
                  ),
                  SizedBox(height: AppSpacing.xl),
                  _Actions(
                    gallery: gallery,
                    resumePage: progress?.page,
                  ),
                  if (gallery.anomalies.isNotEmpty) ...[
                    SizedBox(height: AppSpacing.xl),
                    _AnomalyPanel(gallery: gallery),
                  ],
                  if (detail.pagesDetail.isNotEmpty) ...[
                    SizedBox(height: AppSpacing.xl),
                    Text('页面', style: theme.typography.body.lg),
                    SizedBox(height: AppSpacing.md),
                    _PageGrid(detail: detail),
                  ],
                  SizedBox(height: AppSpacing.xl),
                  _TechnicalPanel(detail: detail),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 并排布局的宽度阈值。
const double _wideBreakpoint = 720;

/// 宽布局下的封面宽度。
const double _coverWide = 260;

/// 窄布局下的封面宽度。
const double _coverNarrow = 130;

/// 正文最大宽度：再宽行就长得难以阅读。
const double _contentMaxWidth = 1000;

class _Cover extends StatelessWidget {
  const _Cover({required this.gallery});

  final GalleryVo gallery;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 0.7,
      child: FCard(
        clipBehavior: Clip.antiAlias,
        child: gallery.coverUrl.isEmpty
            ? ColoredBox(
                color: context.theme.colors.muted,
                child: Center(
                  child: Icon(
                    FLucideIcons.imageOff,
                    size: AppIcon.lg,
                    color: context.theme.colors.mutedForeground,
                  ),
                ),
              )
            : ServerImage(
                path: gallery.coverUrl,
                fit: BoxFit.cover,
                semanticLabel: gallery.displayTitle,
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.gallery, required this.detail});

  final GalleryVo gallery;
  final GalleryDetailVo detail;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(gallery.displayTitle, style: theme.typography.body.xl2),
        if (gallery.titleJpn.isNotEmpty && gallery.titleJpn != gallery.title) ...[
          SizedBox(height: AppSpacing.xs),
          Text(
            gallery.titleJpn,
            style: theme.typography.body.md.copyWith(
              color: theme.colors.mutedForeground,
            ),
          ),
        ],
        SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            _Pill(icon: FLucideIcons.bookOpen, text: '${gallery.pagesFound} 页'),
            if (gallery.simpleLanguage.isNotEmpty)
              _Pill(
                icon: FLucideIcons.languages,
                text: languageLabel(gallery.simpleLanguage),
              ),
            if (gallery.rating > 0)
              _Pill(
                icon: FLucideIcons.star,
                text: '${gallery.rating.toStringAsFixed(1)} 分',
              ),
            if (gallery.totalBytes > 0)
              _Pill(
                icon: FLucideIcons.hardDrive,
                text: formatBytes(gallery.totalBytes),
              ),
            if (gallery.label.isNotEmpty)
              _Pill(icon: FLucideIcons.tag, text: gallery.label),
            _Pill(
              icon: FLucideIcons.layoutGrid,
              // 分类名是推测的，所以把原始数字一起显示，猜错时看得见。
              text: '${categoryLabel(gallery.category)} #${gallery.category}',
            ),
            _Pill(
              icon: gallery.availability == Availability.missing
                  ? FLucideIcons.cloudOff
                  : FLucideIcons.folderOpen,
              text: gallery.availability.label,
            ),
          ],
        ),
        SizedBox(height: AppSpacing.md),
        // 目录名解析出来的标签：值的写法与筛选面板里的分组名一致，所以这里看到
        // 什么，筛选里就能点到什么。
        for (final dimension in TagDimension.values)
          if (gallery.tagsOf(dimension).isNotEmpty)
            _KeyValue(
              label: dimension.label,
              value: gallery.tagsOf(dimension).join('、'),
            ),
        if (gallery.uploader.isNotEmpty)
          _KeyValue(label: '上传者', value: gallery.uploader),
        if (gallery.posted.isNotEmpty)
          _KeyValue(label: '发布于', value: gallery.posted),
        if (gallery.downloadTimeMs > 0)
          _KeyValue(
            label: '加入下载',
            value: formatDateTime(gallery.downloadTimeMs),
          ),
        _KeyValue(label: '元数据来源', value: gallery.metaSource.label),
        if (gallery.titleSource == TitleSource.dirname)
          _KeyValue(
            label: '标题来源',
            value: '目录名（该画廊不在数据库快照中）',
            warn: true,
          ),
      ],
    );
  }
}

/// 阅读入口。有进度时变成「继续阅读」并直接跳到那一页。
class _Actions extends StatelessWidget {
  const _Actions({required this.gallery, required this.resumePage});

  final GalleryVo gallery;
  final int? resumePage;

  @override
  Widget build(BuildContext context) {
    final page = resumePage;
    final canRead = gallery.isReadable;
    final target = page == null ? '/gallery/${gallery.gid}/read' : '/gallery/${gallery.gid}/read?page=$page';

    return Row(
      children: [
        FButton(
          onPress: canRead ? () => context.go(target) : null,
          prefix: const Icon(FLucideIcons.bookOpen, size: AppIcon.sm),
          child: Text(
            page == null ? '开始阅读' : '继续阅读（第 ${page + 1} 页）',
          ),
        ),
        if (!canRead) ...[
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              gallery.onDisk ? '本地文件不可读（页数为 0）' : '目录尚未同步到服务器',
              style: context.theme.typography.body.sm.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 一致性问题面板。
///
/// 这些不是警告装饰：页数不符意味着阅读时会跳页，缺 `.ehviewer` 意味着 gid 或
/// token 只能从目录名猜——用户需要知道，而不是在阅读时自己发现。
class _AnomalyPanel extends StatelessWidget {
  const _AnomalyPanel({required this.gallery});

  final GalleryVo gallery;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: theme.colors.secondary,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                FLucideIcons.circleAlert,
                size: AppIcon.sm,
                color: theme.colors.secondaryForeground,
              ),
              SizedBox(width: AppSpacing.sm),
              Text(
                '一致性提示',
                style: theme.typography.body.md.copyWith(
                  color: theme.colors.secondaryForeground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm),
          for (final anomaly in gallery.anomalies)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                '• ${anomaly.description}',
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.secondaryForeground,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 页面缩略图网格。
///
/// 走 [ServerImage] 而不是 `Image.network`：请求必须带会话，而后者设不了头。
class _PageGrid extends StatelessWidget {
  const _PageGrid({required this.detail});

  final GalleryDetailVo detail;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 120).floor().clamp(3, 10);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: AppSpacing.sm,
            mainAxisSpacing: AppSpacing.sm,
            childAspectRatio: 0.7,
          ),
          itemCount: detail.pagesDetail.length,
          itemBuilder: (context, index) {
            final page = detail.pagesDetail[index];
            return FCard(
              clipBehavior: Clip.antiAlias,
              child: ServerImage(
                path: page.url,
                fit: BoxFit.cover,
                semanticLabel: '第 ${index + 1} 页',
              ),
            );
          },
        );
      },
    );
  }
}

/// 排查用的技术细节：文件系统事实与元数据来源的差异都摆在这里。
class _TechnicalPanel extends StatelessWidget {
  const _TechnicalPanel({required this.detail});

  final GalleryDetailVo detail;

  @override
  Widget build(BuildContext context) {
    final gallery = detail.gallery;
    final spider = detail.spiderInfo;

    return FCard(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('技术细节', style: context.theme.typography.body.md),
            SizedBox(height: AppSpacing.sm),
            _KeyValue(label: 'gid', value: '${gallery.gid}'),
            if (gallery.token.isNotEmpty)
              _KeyValue(label: 'token', value: gallery.token),
            if (gallery.dirName.isNotEmpty)
              _KeyValue(label: '目录名', value: gallery.dirName),
            _KeyValue(
              label: '页数',
              value: '磁盘 ${gallery.pagesFound} · 元数据 ${gallery.pagesExpected}',
              warn: gallery.missingPageCount != null,
            ),
            _KeyValue(
              label: '.ehviewer',
              // 缺失就说缺失：gid/token 此时只能从目录名猜，这是排查问题的关键
              // 一条信息。用 present 而不是 null 判断——该 VO 缺省是 empty 而
              // 不是 null，所以每个调用点都不需要空检查。
              value: spider.present
                  ? 'v${spider.version} · 起始页 ${spider.startPage} · 预览 ${spider.previewPages}'
                  : '缺失',
              warn: !spider.present,
            ),
            _KeyValue(label: '封面来源', value: gallery.coverKind),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.colors.secondary,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppIcon.sm, color: theme.colors.secondaryForeground),
          SizedBox(width: AppSpacing.xs),
          Text(
            text,
            style: theme.typography.body.xs.copyWith(
              color: theme.colors.secondaryForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({
    required this.label,
    required this.value,
    this.warn = false,
  });

  final String label;
  final String value;
  final bool warn;

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
              style: theme.typography.body.xs.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.typography.body.sm.copyWith(
                color: warn ? theme.colors.error : theme.colors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 键列宽度：标签最长是「元数据来源」（5 个字），留出余量后固定住，让右侧的
/// 值始终对齐。
const double _labelWidth = 76;
