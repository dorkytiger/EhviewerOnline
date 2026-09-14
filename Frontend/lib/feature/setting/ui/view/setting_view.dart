import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
// SelectableText 与 ThemeMode 都来自 material_ui：Flutter 3.44 起 Material 已从
// SDK 独立成包，forui 0.26 也建立在它之上；`package:flutter/material.dart` 是
// 另一套实现，类型互不兼容。这里只取这两个符号，避免把 Material 组件也带进视野。
import 'package:material_ui/material_ui.dart' show SelectableText, ThemeMode;

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/confirm_dialog.dart';
import '../../../../common/widget/custom_error_widget.dart';
import '../../../../common/widget/server_address_dialog.dart';
import '../../../../core/service/local_prefs.dart';
import '../../../../core/service/server_address.dart';
import '../../../../core/service/thumbnail_cache.dart';
import '../../../../core/util/format_util.dart';
import '../../../../core/util/message_util.dart';
import '../../../../core/util/result_util.dart';
import '../../../library/model/vo/server_meta_vo.dart';
import '../../../library/ui/provider/server_meta_provider.dart';
import '../provider/setting_provider.dart';

/// 设置页：服务器信息与地址、外观、阅读器、会话。
///
/// 服务器元数据区块是「诚实」的那一块：它明确说明快照有多旧、服务端自己报了
/// 哪些警告，因为应用里其他地方的计数都只和这份快照一样准确。
class SettingView extends ConsumerWidget {
  const SettingView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    final prefs = ref.watch(localPrefsProvider);
    final baseUrl = ref.watch(serverAddressProvider);
    final meta = ref.watch(serverMetaProvider);

    return FScaffold(
      // 留白由列表自己控制：整页统一 padding 会让卡片贴边或双重留白（FScaffold
      // 默认那层左右 12 px 已在品牌主题里归零，见 app_theme.dart）。
      header: FHeader(
        title: const Text('设置'),
        suffixes: [
          FHeaderAction(
            icon: const Icon(FLucideIcons.refreshCw),
            semanticsTooltip: '刷新服务器信息',
            onPress: () => ref.invalidate(serverMetaProvider),
          ),
        ],
      ),
      child: ListView(
        padding: theme.style.pagePadding,
        children: [
          const _SectionTitle('服务器'),
          meta.when(
            loading: () => const _MetaLoadingCard(),
            // 地址写错时这里只会是错误；修它的控件在下面，不依赖这一块加载成功。
            error: (error, _) => FCard(
              child: CustomErrorWidget(
                error: error,
                onRetry: () => ref.invalidate(serverMetaProvider),
              ),
            ),
            data: (value) => _ServerMetaSection(meta: value),
          ),
          SizedBox(height: AppSpacing.md),
          _ServerAddressCard(baseUrl: baseUrl),
          SizedBox(height: AppSpacing.xl),

          const _SectionTitle('外观'),
          _PrefCard(
            children: [
              FSelectGroup<ThemeMode>(
                control: FMultiValueControl<ThemeMode>.lifted(
                  value: {prefs.themeMode},
                  onChange: (values) {
                    final mode = _picked(values);
                    if (mode != null) {
                      _applyPref(
                        context,
                        () => ref
                            .read(localPrefsProvider.notifier)
                            .setThemeMode(mode),
                      );
                    }
                  },
                ),
                children: [
                  for (final mode in ThemeMode.values)
                    FSelectGroupItemMixin.radio<ThemeMode>(
                      value: mode,
                      label: Text(_themeLabel(mode)),
                    ),
                ],
              ),
            ],
          ),
          SizedBox(height: AppSpacing.xl),

          const _SectionTitle('阅读器'),
          _PrefCard(
            children: [
              FSelectGroup<ReaderDirection>(
                control: FMultiValueControl<ReaderDirection>.lifted(
                  value: {prefs.readerDirection},
                  onChange: (values) {
                    final direction = _picked(values);
                    if (direction != null) {
                      _applyPref(
                        context,
                        () => ref
                            .read(localPrefsProvider.notifier)
                            .setReaderDirection(direction),
                      );
                    }
                  },
                ),
                children: [
                  for (final direction in ReaderDirection.values)
                    FSelectGroupItemMixin.radio<ReaderDirection>(
                      value: direction,
                      label: Text(direction.label),
                      description: Text(direction.description),
                    ),
                ],
              ),
              const FDivider(),
              FSelectGroup<ReaderFit>(
                control: FMultiValueControl<ReaderFit>.lifted(
                  value: {prefs.fitMode},
                  onChange: (values) {
                    final fit = _picked(values);
                    if (fit != null) {
                      _applyPref(
                        context,
                        () =>
                            ref.read(localPrefsProvider.notifier).setFitMode(fit),
                      );
                    }
                  },
                ),
                children: [
                  for (final fit in ReaderFit.values)
                    FSelectGroupItemMixin.radio<ReaderFit>(
                      value: fit,
                      label: Text(fit.label),
                      description: Text(fit.description),
                    ),
                ],
              ),
            ],
          ),
          SizedBox(height: AppSpacing.xl),

          const _SectionTitle('存储'),
          const _ImageCacheCard(),
          SizedBox(height: AppSpacing.xl),

          const _SectionTitle('会话'),
          FButton(
            variant: FButtonVariant.destructive,
            onPress: () => _confirmLogout(context, ref),
            prefix: const Icon(FLucideIcons.logOut),
            child: const Text('退出登录'),
          ),
          SizedBox(height: AppSpacing.md),
          Text(
            '阅读进度只保存在本机，不会写回服务器：后端按设计是只读的，'
            '写入同步目录会与 Syncthing 产生冲突。',
            style: theme.typography.body.xs.copyWith(
              color: theme.colors.mutedForeground,
            ),
          ),
          SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}

/// 写入一项本地偏好，失败时给出原因。
///
/// 偏好写入会真的失败（磁盘满、平台通道异常）。失败了却没有任何提示，是用户
/// 唯一无法自行诊断的一类问题——他们只会以为应用坏了。
///
/// 成功不弹 toast：主题/方向改完立刻可见，界面本身就是反馈。
Future<void> _applyPref(
  BuildContext context,
  Future<Result<void>> Function() write,
) async {
  final result = await write();
  if (!context.mounted) return;
  final error = result.error;
  if (error == null) return;
  showFToast(
    context: context,
    variant: FToastVariant.destructive,
    title: const Text('保存失败'),
    description: Text(messageOf(error)),
  );
}

/// 退出登录：先二次确认，再交给 viewmodel。
///
/// 文案必须写清后果——退出后要重新输入访问令牌才能继续用，这不是一个「点错了
/// 也没关系」的操作。
Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
  final confirmed = await confirmDialog(
    context,
    title: '退出登录',
    message: '需要重新输入访问令牌才能继续使用。',
    confirmLabel: '退出',
  );
  if (!confirmed || !context.mounted) {
    return;
  }

  final error = await ref.read(settingActionProvider.notifier).logout();
  if (!context.mounted || error == null) {
    return;
  }
  showFToast(
    context: context,
    variant: FToastVariant.destructive,
    title: const Text('退出失败'),
    description: Text(error),
  );
}


/// 服务器地址，可点可改。
///
/// 它刻意放在元数据区块**之外**：地址错的时候每一次请求都会失败，元数据区块
/// 只能显示一个错误——修它的控件绝不能依赖那个区块加载成功。
class _ServerAddressCard extends ConsumerWidget {
  const _ServerAddressCard({required this.baseUrl});

  final String baseUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FTileGroup(
      children: [
        FTile(
          title: const Text('服务器地址'),
          subtitle: SelectableText(baseUrl),
          suffix: const Icon(FLucideIcons.pencil),
          semanticsTooltip: '修改服务器地址',
          onPress: () => _edit(context, ref),
        ),
      ],
    );
  }

  /// 弹窗本身在 `common/widget`，因为登录页也要用同一个——未登录时设置页进不来，
  /// 那里是唯一的自救出口。
  ///
  /// 失效哪些 provider 由调用方决定：弹窗属于 common，不该知道有哪些 feature
  /// 关心地址变化。
  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final changed = await showServerAddressDialog(context, initial: baseUrl);
    if (!changed) return;
    // 「谁需要跟着变」属于 UI 状态编排，留在 viewmodel 里而不是这里。
    ref.read(settingActionProvider.notifier).afterServerChange();
  }
}

/// 元数据加载中的占位。
class _MetaLoadingCard extends StatelessWidget {
  const _MetaLoadingCard();

  @override
  Widget build(BuildContext context) {
    return FCard(
      child: Padding(
        padding: context.theme.style.pagePadding,
        child: const Center(child: FCircularProgress()),
      ),
    );
  }
}

/// 服务器元数据：索引统计、快照新鲜度、功能开关与警告。
class _ServerMetaSection extends StatelessWidget {
  const _ServerMetaSection({required this.meta});

  final ServerMetaVo meta;

  @override
  Widget build(BuildContext context) {
    final snapshotAge =
        meta.snapshotAtMs == 0 ? null : formatRelative(meta.snapshotAtMs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTileGroup(
          children: [
            _InfoTile(
              label: '服务版本',
              value: meta.version.isEmpty ? '未知' : meta.version,
            ),
            _InfoTile(label: '画廊总数', value: '${meta.galleries}'),
            _InfoTile(label: '本地可读', value: '${meta.onDisk}'),
            _InfoTile(
              label: '未同步',
              value: '${meta.missing}',
              warn: meta.missing > 0,
            ),
            _InfoTile(
              label: '异常',
              value: '${meta.degraded}',
              warn: meta.degraded > 0,
            ),
            _InfoTile(label: '总页数', value: '${meta.pages}'),
            _InfoTile(label: '占用空间', value: formatBytes(meta.totalBytes)),
            _InfoTile(
              label: '跳过的目录',
              value: '${meta.skippedDirs}',
              warn: meta.skippedDirs > 0,
            ),
          ],
        ),
        SizedBox(height: AppSpacing.md),
        FTileGroup(
          children: [
            _InfoTile(
              label: '数据库快照',
              value: meta.snapshotAtMs == 0
                  ? '无（标题来自目录名）'
                  : '${meta.snapshotFile.isEmpty ? '' : '${meta.snapshotFile} · '}'
                      '${formatDateTime(meta.snapshotAtMs)}（$snapshotAge）',
              warn: meta.snapshotAtMs == 0,
            ),
            _InfoTile(
              label: '索引建立于',
              value: formatRelative(meta.indexedAtMs),
            ),
            _InfoTile(
              label: '按标签筛选',
              value: meta.supportsTags ? '支持' : '不支持（导出库无 Gallery_Tags 表）',
            ),
            _InfoTile(
              label: '缩略图',
              value: meta.supportsThumbnails ? '服务端生成' : '不可用',
            ),
            _InfoTile(
              label: '实时推送',
              value: meta.supportsSse ? '支持' : '不支持（需手动刷新）',
            ),
          ],
        ),
        if (meta.warnings.isNotEmpty) ...[
          SizedBox(height: AppSpacing.md),
          FAlert(
            icon: const Icon(FLucideIcons.triangleAlert),
            title: const Text('服务器提示'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final warning in meta.warnings) Text('• $warning'),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 一行「标签 + 值」。
///
/// 值放在 subtitle 而不是 details：details 是右对齐单行且会被截断，而这里的值
/// （快照文件名加时间、功能说明）经常很长，需要换行完整显示。
/// [FTileMixin] 是 [FTileGroup] 认子项的标记接口：组只知道把子项包进它自己的
/// item 样式里，所以这里的包装类必须显式带上它，否则进不了 `children` 列表。
class _InfoTile extends StatelessWidget with FTileMixin {
  const _InfoTile({required this.label, required this.value, this.warn = false});

  final String label;
  final String value;

  /// 需要提醒的项（未同步、异常、没有快照）用错误色标出来，而不是只靠数字。
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return FTile(
      title: Text(label),
      subtitle: Text(
        value,
        style: theme.typography.body.xs.copyWith(
          color: warn ? theme.colors.error : theme.colors.mutedForeground,
        ),
      ),
    );
  }
}

/// 分组标题。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        text,
        style: theme.typography.body.lg.copyWith(
          color: theme.colors.foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 缩略图缓存：开关 + 占用 + 清除。
///
/// 占用是**异步统计**出来的（要遍历缓存目录），所以进来才第一次算、清空后重算。
/// 没有「统计失败」这一态——`FileStore` 把 I/O 错误折叠成 0；真正需要区分的是
/// **没有磁盘层的平台**（Web）：那里占用恒为 0，必须换一句话说，否则显示「0 B」
/// 会让人以为缓存是空的，而实际是根本不存在。
class _ImageCacheCard extends ConsumerStatefulWidget {
  const _ImageCacheCard();

  @override
  ConsumerState<_ImageCacheCard> createState() => _ImageCacheCardState();
}

class _ImageCacheCardState extends ConsumerState<_ImageCacheCard> {
  /// null = 还没统计出来。
  int? _bytes;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final bytes = await ref.read(thumbnailCacheProvider).sizeBytes();
    if (!mounted) return;
    setState(() => _bytes = bytes);
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    final result = await ref.read(thumbnailCacheProvider).clear();
    if (!mounted) return;

    setState(() => _clearing = false);
    await _measure();
    if (!mounted) return;

    final error = result.error;
    showFToast(
      context: context,
      variant: error == null ? FToastVariant.primary : FToastVariant.destructive,
      title: Text(error == null ? '缓存已清除' : '清除失败'),
      description: error == null ? null : Text(messageOf(error)),
    );
  }

  String _summary({required bool persistent, required int? bytes}) {
    if (!persistent) return '占用不可统计：当前平台没有文件系统';
    if (bytes == null) return '正在统计…';
    if (bytes == 0) return '缓存为空';
    return '当前占用 ${formatBytes(bytes)}';
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(localPrefsProvider);
    final theme = context.theme;
    final cache = ref.watch(thumbnailCacheProvider);
    final bytes = _bytes;
    // 缓存为空时没有可清除的东西，禁用比点了没反应诚实。
    final clearable = bytes != null && bytes > 0 && !_clearing;

    return _PrefCard(
      children: [
        FTileGroup(
          children: [
            FTile(
              title: const Text('缓存封面缩略图'),
              subtitle: Text(
                !prefs.imageCacheEnabled
                    ? '已关闭：每次浏览都会重新下载封面'
                    : cache.persistent
                        ? '封面只下载一次，重启后仍命中'
                        : '此平台没有文件系统，缓存只在本次运行内有效',
              ),
              suffix: FSwitch(
                value: prefs.imageCacheEnabled,
                onChange: (value) => _applyPref(
                  context,
                  () => ref
                      .read(localPrefsProvider.notifier)
                      .setImageCacheEnabled(value),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: Text(
                _summary(persistent: cache.persistent, bytes: bytes),
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ),
            FButton(
              variant: FButtonVariant.outline,
              onPress: clearable ? _clear : null,
              prefix: const Icon(FLucideIcons.trash2, size: AppIcon.sm),
              child: Text(_clearing ? '清除中…' : '清除缓存'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 承载一组偏好控件的卡片。
class _PrefCard extends StatelessWidget {
  const _PrefCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return FCard(
      child: Padding(
        padding: context.theme.style.pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// 单选组当前选中的值。
///
/// forui 0.26 没有单选版的 `FRadioGroup`：单选是用 [FSelectGroup] 的 radio 项
/// 加提升状态（[FMultiValueControl.lifted]）模拟的，而它的状态是一个**集合**。
/// 点击只会把新值加进去、不会移除旧值，所以新选中的值总是最后加入的那个；
/// 点已选中的项不会触发回调，集合因此不会无限增长。
T? _picked<T>(Set<T> values) => values.isEmpty ? null : values.last;

/// 主题选项的文案。
///
/// [ThemeMode] 是 material_ui 的枚举，加不了 label 字段，所以映射集中放在这里
/// ——别处不得再 switch 主题文案。
String _themeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => '跟随系统',
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
    };
