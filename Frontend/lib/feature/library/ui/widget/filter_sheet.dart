import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/custom_error_widget.dart';
import '../../../../common/widget/f_sheet_content.dart';
import '../../../../core/util/format_util.dart';
import '../../enum/availability.dart';
import '../../enum/tag_dimension.dart';
import '../../model/state/library_filter_state.dart';
import '../../model/vo/facet_value_vo.dart';
import '../../model/vo/facets_vo.dart';
import '../provider/facets_provider.dart';
import '../provider/library_filter_provider.dart';

/// 打开筛选面板。
///
/// 用 forui 的 [showFSheet]（而不是 Material 的 `showModalBottomSheet`）：主题、
/// 拖拽手势与安全区都由组件库统一处理，两套实现并存只会长出不一致的面板。
Future<void> showFilterSheet(BuildContext context) => showFSheet<void>(
      context: context,
      side: FLayout.btt,
      builder: (context) => const FilterSheet(),
    );

/// 由服务端候选集驱动的筛选控件。
///
/// 每个选项都来自 `/api/v1/facets`，所以面板只可能提供真实存在的值。这比听上去
/// 更重要：标签维度是从目录名推导的，与其自己猜有哪些汉化组，不如让服务端报。
///
/// **标签分区排在最前面**：它们是唯一不依赖数据库导出的筛选维度。下面四个
/// （可用性/标签/语言/分类）读的是快照，而快照需要有人在手机上手动「导出数据」
/// 才会有——新装的库里它们是空的，标签分区就是整个面板。
class FilterSheet extends ConsumerWidget {
  const FilterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryFilterProvider);
    final notifier = ref.read(libraryFilterProvider.notifier);
    final facetsAsync = ref.watch(facetsProvider);

    return FSheetContent(
      title: '筛选',
      trailing: filter.activeCount > 0
          ? FButton(
              variant: FButtonVariant.ghost,
              onPress: notifier.clear,
              child: const Text('清除'),
            )
          : null,
      child: facetsAsync.when(
        loading: () => const Center(child: FCircularProgress()),
        error: (error, _) => CustomErrorWidget(
          error: error,
          onRetry: () => ref.invalidate(facetsProvider),
        ),
        data: (facets) => ListView(
          shrinkWrap: true,
          children: [
            _TagSections(facets: facets, filter: filter),
            _SingleSection(
              title: '可用性',
              subtitle: '「未同步」表示数据库有记录但本地目录缺失',
              facets: facets.availability,
              selected: filter.availability?.name,
              labelOf: (value) => Availability.parse(value).label,
              onChanged: (value) {
                if (value == null) {
                  notifier.toggleAvailability(Availability.unknown);
                  return;
                }
                final parsed = Availability.parse(value);
                if (parsed != Availability.unknown) {
                  notifier.toggleAvailability(parsed);
                }
              },
            ),
            _SingleSection(
              title: '标签',
              subtitle: '来自数据库快照的下载标签',
              facets: facets.labels,
              selected: filter.label.isEmpty ? null : filter.label,
              labelOf: (value) => value.isEmpty ? '(无标签)' : value,
              onChanged: (value) => notifier.toggleLabel(value ?? ''),
            ),
            _SingleSection(
              title: '语言',
              subtitle: '来自 simple_language，缺失时由标题推断',
              facets: facets.languages,
              selected: filter.language.isEmpty ? null : filter.language,
              labelOf: languageLabel,
              onChanged: (value) => notifier.toggleLanguage(value ?? ''),
            ),
            _SingleSection(
              title: '分类',
              subtitle: '分类名称是推测的，数字为服务器的原始值',
              facets: facets.categories,
              selected: filter.category?.toString(),
              labelOf: (value) {
                final parsed = int.tryParse(value);
                final name = parsed == null ? value : categoryLabel(parsed);
                return '$name #$value';
              },
              onChanged: (value) {
                if (value == null) {
                  notifier.toggleCategory(-1);
                  return;
                }
                final parsed = int.tryParse(value);
                if (parsed != null) notifier.toggleCategory(parsed);
              },
            ),
            SizedBox(height: AppSpacing.md),
            _Note(
              '标签是从「<gid>-标题」这个目录名解析出来的，所以不需要数据库导出。'
              'E-Hentai 的官方标签仍然不可用：导出的数据库不包含 Gallery_Tags 表。',
            ),
          ],
        ),
      ),
    );
  }
}

/// 目录名推导出的五个维度，每个一个多选控件。
///
/// 同维度内多选表示「任一」（服务端对同维度取 OR），这也是为什么用多选而不是
/// 下拉单选：想一次看两个汉化组，单选做不到。
class _TagSections extends ConsumerWidget {
  const _TagSections({required this.facets, required this.filter});

  final FacetsVo facets;
  final LibraryFilterState filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final present = TagDimension.values
        .where((d) => d.of(facets).isNotEmpty)
        .toList(growable: false);
    if (present.isEmpty) return const SizedBox.shrink();

    final notifier = ref.read(libraryFilterProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '标签',
          subtitle: '从目录名解析而来。同一组内多选表示「任一」，不同组之间是「同时满足」。',
        ),
        for (final dimension in present) ...[
          SizedBox(height: AppSpacing.md),
          FMultiSelect<String>(
            label: Text(dimension.label),
            items: {
              for (final facet in dimension.of(facets))
                // label 是库里真实用过的拼写，value 是服务端筛选用的归一化键。
                '${facet.display} (${facet.count})': facet.value,
            },
            control: FMultiValueControl<String>.lifted(
              value: filter.tagsOf(dimension),
              onChange: (values) => notifier.setTags(dimension, values),
            ),
            hint: const Text('全部'),
          ),
        ],
        SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// 快照维度：单选，可清空。
class _SingleSection extends StatelessWidget {
  const _SingleSection({
    required this.title,
    required this.subtitle,
    required this.facets,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final List<FacetValueVo> facets;
  final String? selected;
  final String Function(String value) labelOf;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (facets.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(title: title, subtitle: subtitle),
          SizedBox(height: AppSpacing.sm),
          FSelect<String>(
            items: {
              for (final facet in facets)
                '${labelOf(facet.value)} (${facet.count})': facet.value,
            },
            control: FSelectControl<String>.lifted(
              value: selected,
              onChange: onChanged,
            ),
            clearable: true,
            hint: '全部',
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.typography.body.md.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colors.foreground,
          ),
        ),
        SizedBox(height: AppSpacing.xs),
        Text(
          subtitle,
          style: theme.typography.body.xs.copyWith(
            color: theme.colors.mutedForeground,
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Text(
      text,
      style: theme.typography.body.xs.copyWith(
        color: theme.colors.mutedForeground,
      ),
    );
  }
}
