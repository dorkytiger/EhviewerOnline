import '../../enum/availability.dart';
import '../../enum/gallery_anomaly.dart';
import '../../enum/meta_source.dart';
import '../../enum/tag_dimension.dart';
import '../../enum/title_source.dart';
import 'json_coerce.dart';

/// 列表接口返回的画廊。
///
/// [fromJson] 是这一层唯一的 JSON 入口：字段解析全部收敛在这里，别处不得再
/// `json['x']` 裸取。解析策略沿用旧实现：**元数据字段容错**（服务端还没发的
/// 字段退化成安全默认值，不能让整屏挂掉），**枚举字段严格**（未知值落到显式的
/// `unknown`，因为把可用性标错比标成「未知」更糟）。
class GalleryVo {
  const GalleryVo({
    required this.gid,
    required this.token,
    required this.title,
    required this.titleJpn,
    required this.titleSource,
    required this.dirName,
    required this.artists,
    required this.groups,
    required this.series,
    required this.events,
    required this.editions,
    required this.category,
    required this.posted,
    required this.uploader,
    required this.rating,
    required this.simpleLanguage,
    required this.label,
    required this.state,
    required this.downloadTimeMs,
    required this.pagesExpected,
    required this.pagesFound,
    required this.totalBytes,
    required this.coverUrl,
    required this.coverKind,
    required this.availability,
    required this.anomalies,
    required this.metaSource,
    required this.onDisk,
  });

  final int gid;
  final String token;
  final String title;
  final String titleJpn;
  final TitleSource titleSource;
  final String dirName;

  /// 从目录名解析出来的，不是快照里的。仅供参考：服务端会折叠大小写，解析也
  /// 是启发式的，所以「没解析出某个标签」不能证明它不存在。
  final List<String> artists;
  final List<String> groups;
  final List<String> series;
  final List<String> events;
  final List<String> editions;
  final int category;
  final String posted;
  final String uploader;
  final double rating;
  final String simpleLanguage;
  final String label;
  final int state;
  final int downloadTimeMs;
  final int pagesExpected;
  final int pagesFound;
  final int totalBytes;
  final String coverUrl;
  final String coverKind;
  final Availability availability;
  final List<GalleryAnomaly> anomalies;
  final MetaSource metaSource;
  final bool onDisk;

  factory GalleryVo.fromJson(Map<String, dynamic> json) => GalleryVo(
        gid: intOr(json['gid']),
        token: stringOr(json['token']),
        title: stringOr(json['title']),
        titleJpn: stringOr(json['title_jpn']),
        titleSource: TitleSource.parse(stringOrNull(json['title_source'])),
        dirName: stringOr(json['dir_name']),
        artists: stringListOr(json['artists']),
        groups: stringListOr(json['groups']),
        series: stringListOr(json['series']),
        events: stringListOr(json['events']),
        editions: stringListOr(json['editions']),
        category: intOr(json['category']),
        posted: stringOr(json['posted']),
        uploader: stringOr(json['uploader']),
        rating: doubleOr(json['rating']),
        simpleLanguage: stringOr(json['simple_language']),
        label: stringOr(json['label']),
        state: intOr(json['state']),
        downloadTimeMs: intOr(json['download_time_ms']),
        pagesExpected: intOr(json['pages_expected']),
        pagesFound: intOr(json['pages_found']),
        totalBytes: intOr(json['total_bytes']),
        coverUrl: stringOr(json['cover_url']),
        coverKind: stringOr(json['cover_kind']),
        availability: Availability.parse(stringOrNull(json['availability'])),
        anomalies: anomaliesOr(json['anomalies']),
        metaSource: MetaSource.parse(stringOrNull(json['meta_source'])),
        onDisk: json['on_disk'] == true,
      );

  /// 紧凑布局用的一行标题。
  String get displayTitle {
    if (title.isNotEmpty) return title;
    if (titleJpn.isNotEmpty) return titleJpn;
    // 服务端总会给一个，但兜底一个值也好过渲染出空行。
    return '#$gid';
  }

  /// 该画廊在某个派生标签维度上的取值。
  List<String> tagsOf(TagDimension dimension) => switch (dimension) {
        TagDimension.artist => artists,
        TagDimension.group => groups,
        TagDimension.series => series,
        TagDimension.event => events,
        TagDimension.edition => editions,
      };

  /// 是否真的能读。
  bool get isReadable => onDisk && pagesFound > 0;

  /// 相对元数据声明缺失的页数。
  ///
  /// 只在元数据存在时才有意义；否则「声明了多少页」是未知而不是 0。
  int? get missingPageCount {
    if (pagesExpected <= 0 || pagesFound >= pagesExpected) return null;
    return pagesExpected - pagesFound;
  }

  /// 是否带有值得打断用户的异常。
  bool get hasSevereAnomaly => anomalies.any((a) => a.isSevere);
}
