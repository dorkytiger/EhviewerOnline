import '../../enum/availability.dart';
import '../../enum/gallery_sort.dart';
import '../../enum/tag_dimension.dart';

/// 画廊查询的筛选条件。
///
/// 不可变 + `copyWith`：它喂给 Riverpod provider，而可变的筛选状态是「列表怎么
/// 没刷新」这类 bug 的稳定来源。
class LibraryFilterState {
  const LibraryFilterState({
    this.text = '',
    this.label = '',
    this.language = '',
    this.category,
    this.availability,
    this.tags = const {},
    this.sort = GallerySort.timeDesc,
  });

  final String text;
  final String label;
  final String language;
  final int? category;
  final Availability? availability;

  /// 每个标签维度已选的值。某个维度没选任何值时直接不存在，所以
  /// `tags.isEmpty` 和「没有标签筛选」是同一个问题。
  final Map<TagDimension, Set<String>> tags;

  final GallerySort sort;

  /// 某个维度已选的值，永不为 null。
  Set<String> tagsOf(TagDimension dimension) => tags[dimension] ?? const {};

  /// 返回切换了某个标签值的副本。
  ///
  /// 一个维度存的是集合而不是单选，因为服务端在同一维度内做 OR：再选一个作者
  /// 是把结果放宽到「任一」，这正是用户读候选项列表时的预期。选完一个再选另一
  /// 个，绝不能悄悄替掉前一个。
  LibraryFilterState toggleTag(TagDimension dimension, String value) {
    final selected = {...tagsOf(dimension)};
    if (!selected.remove(value)) selected.add(value);

    final merged = {...tags};
    if (selected.isEmpty) {
      merged.remove(dimension);
    } else {
      merged[dimension] = selected;
    }
    return copyWith(tags: merged);
  }

  /// 是否没有任何筛选条件。
  bool get isEmpty =>
      text.isEmpty &&
      label.isEmpty &&
      language.isEmpty &&
      category == null &&
      availability == null &&
      tags.isEmpty;

  /// 开了几个筛选条件。每个已选标签算一个，因为每个都是用户必须单独清掉的
  /// chip。
  int get activeCount {
    var n = 0;
    if (text.isNotEmpty) n++;
    if (label.isNotEmpty) n++;
    if (language.isNotEmpty) n++;
    if (category != null) n++;
    if (availability != null) n++;
    for (final selected in tags.values) {
      n += selected.length;
    }
    return n;
  }

  LibraryFilterState copyWith({
    String? text,
    String? label,
    String? language,
    int? category,
    Availability? availability,
    Map<TagDimension, Set<String>>? tags,
    GallerySort? sort,
    bool clearCategory = false,
    bool clearAvailability = false,
    bool clearLabel = false,
    bool clearLanguage = false,
  }) {
    return LibraryFilterState(
      text: text ?? this.text,
      label: clearLabel ? '' : (label ?? this.label),
      language: clearLanguage ? '' : (language ?? this.language),
      category: clearCategory ? null : (category ?? this.category),
      availability:
          clearAvailability ? null : (availability ?? this.availability),
      tags: tags ?? this.tags,
      sort: sort ?? this.sort,
    );
  }

  /// `/api/v1/galleries` 的查询参数，不含分页。
  Map<String, dynamic> toQuery() => {
        if (text.isNotEmpty) 'q': text,
        if (label.isNotEmpty) 'label': label,
        if (language.isNotEmpty) 'language': language,
        if (category != null) 'category': category,
        if (availability != null) 'availability': availability!.name,
        // 每个已选值一个重复参数；Dio 默认的 list format 是 "multi"，正是服务端
        // 读的形式（q["artist"]）。排序是为了同一套选择永远生成同一个 URL。
        for (final dimension in TagDimension.values)
          if (tagsOf(dimension).isNotEmpty)
            dimension.param: (tagsOf(dimension).toList()..sort()),
        'sort': sort.wire,
      };
}
