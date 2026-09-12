import 'json_coerce.dart';

/// 一个筛选候选项。
class FacetValueVo {
  const FacetValueVo({
    required this.value,
    required this.count,
    this.label = '',
  });

  /// 回传给服务端作为筛选条件的值，也是这个候选项的稳定标识。
  final String value;

  /// 有多少个画廊带这个值。
  final int count;

  /// 给人看的拼写。
  ///
  /// 标签维度会把只有大小写差异的拼写合并，所以它们的 [value] 是归一化后的
  /// 键，而这里是库里真实用过的某种拼写；快照维度没有这个需求，不发该字段。
  final String label;

  /// 展示用文案：[label] 为空时退回 [value]。
  String get display => label.isEmpty ? value : label;

  factory FacetValueVo.fromJson(Map<String, dynamic> json) => FacetValueVo(
        value: stringOr(json['value']),
        count: intOr(json['count']),
        label: stringOr(json['label']),
      );
}

/// 把响应里的候选项数组解成 [FacetValueVo] 列表；类型不符时返回空表。
List<FacetValueVo> facetValueListOr(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map<String, dynamic>>()
      .map(FacetValueVo.fromJson)
      .toList(growable: false);
}
