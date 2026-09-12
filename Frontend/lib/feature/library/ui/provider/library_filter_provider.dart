import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../enum/availability.dart';
import '../../enum/gallery_sort.dart';
import '../../enum/tag_dimension.dart';
import '../../model/state/library_filter_state.dart';

/// 图库列表的筛选状态（viewmodel）。
///
/// 只维护「界面当前选了什么」并把它转成一次不可变替换；查询本身归
/// [LibraryListController]，业务规则归 service。
class LibraryFilterController extends Notifier<LibraryFilterState> {
  @override
  LibraryFilterState build() => const LibraryFilterState();

  /// 搜索词。调用方负责防抖——每次按键都发请求会把列表刷成幻灯片。
  void setText(String text) => state = state.copyWith(text: text);

  void setSort(GallerySort sort) => state = state.copyWith(sort: sort);

  void toggleLabel(String label) => state = state.label == label
      ? state.copyWith(clearLabel: true)
      : state.copyWith(label: label);

  void toggleLanguage(String language) => state = state.language == language
      ? state.copyWith(clearLanguage: true)
      : state.copyWith(language: language);

  void toggleCategory(int category) => state = state.category == category
      ? state.copyWith(clearCategory: true)
      : state.copyWith(category: category);

  void toggleAvailability(Availability availability) =>
      state.availability == availability
          ? state.copyWith(clearAvailability: true)
          : state.copyWith(availability: availability);

  /// 切换一个目录名推导出的标签。
  ///
  /// 变换本身在 [LibraryFilterState] 上：它是纯的，属于它产生的状态，放在
  /// 那里就不需要 provider 容器也能测。
  void toggleTag(TagDimension dimension, String value) =>
      state = state.toggleTag(dimension, value);

  /// 用一组新值整体替换某个维度的选择。
  ///
  /// forui 的多选控件（`FMultiValueControl.lifted`）一次给出的是完整的选中集合，
  /// 而不是「变了哪一个」，所以需要这个入口；逐值 toggle 会让集合语义和控件
  /// 语义对不上。
  void setTags(TagDimension dimension, Set<String> values) {
    final merged = {...state.tags};
    if (values.isEmpty) {
      merged.remove(dimension);
    } else {
      merged[dimension] = values;
    }
    state = state.copyWith(tags: merged);
  }

  /// 清空筛选，保留排序。
  ///
  /// 排序不是「筛选条件」，把它一起清掉会让人每清一次筛选就要重选一次排序。
  void clear() => state = LibraryFilterState(sort: state.sort);
}

final libraryFilterProvider =
    NotifierProvider<LibraryFilterController, LibraryFilterState>(
  LibraryFilterController.new,
);
