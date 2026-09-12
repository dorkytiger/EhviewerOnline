import '../model/vo/facets_vo.dart';
import '../model/vo/facet_value_vo.dart';

/// 从目录名推导出来的标签维度。
///
/// 同步过来的目录树里没有标签数据——导出的快照没有 Gallery_Tags 表，而
/// Syncthing 同步的是文件不是手机数据库——所以服务端靠解析目录名里的站点
/// 命名约定把这些标签还原出来。它们是「从未导出过数据库的库」里唯一还能
/// 过滤的维度。
enum TagDimension {
  artist('artist', '作者/社团', 'artists'),
  group('group', '汉化组', 'groups'),
  series('series', '系列/原作', 'series'),
  event('event', '展会', 'events'),
  edition('edition', '属性/版本', 'editions');

  const TagDimension(this.param, this.label, this.facetKey);

  /// 发送时使用的重复查询参数名。
  final String param;

  /// 筛选面板里的分组标题。
  final String label;

  /// 该维度在 `/api/v1/facets` 响应里的键名。
  final String facetKey;

  /// 该维度的候选项，响应里没有时为空。
  List<FacetValueVo> of(FacetsVo facets) => switch (this) {
        TagDimension.artist => facets.artists,
        TagDimension.group => facets.groups,
        TagDimension.series => facets.series,
        TagDimension.event => facets.events,
        TagDimension.edition => facets.editions,
      };
}
