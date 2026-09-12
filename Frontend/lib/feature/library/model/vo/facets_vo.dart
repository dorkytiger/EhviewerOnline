import 'facet_value_vo.dart';

/// `/api/v1/facets` 返回的聚合筛选维度。
class FacetsVo {
  const FacetsVo({
    required this.labels,
    required this.languages,
    required this.categories,
    required this.availability,
    this.artists = const [],
    this.groups = const [],
    this.series = const [],
    this.events = const [],
    this.editions = const [],
  });

  final List<FacetValueVo> labels;
  final List<FacetValueVo> languages;
  final List<FacetValueVo> categories;
  final List<FacetValueVo> availability;

  /// 从目录名推导，所以和上面四个不同：即使服务端从没见过导出的数据库快照，
  /// 这些维度也存在。
  final List<FacetValueVo> artists;
  final List<FacetValueVo> groups;
  final List<FacetValueVo> series;
  final List<FacetValueVo> events;
  final List<FacetValueVo> editions;

  /// 空候选集：加载失败或尚未加载时的安全默认值。
  static const empty = FacetsVo(
    labels: [],
    languages: [],
    categories: [],
    availability: [],
  );

  factory FacetsVo.fromJson(Map<String, dynamic> json) => FacetsVo(
        labels: facetValueListOr(json['labels']),
        languages: facetValueListOr(json['languages']),
        categories: facetValueListOr(json['categories']),
        availability: facetValueListOr(json['availability']),
        artists: facetValueListOr(json['artists']),
        groups: facetValueListOr(json['groups']),
        series: facetValueListOr(json['series']),
        events: facetValueListOr(json['events']),
        editions: facetValueListOr(json['editions']),
      );
}
