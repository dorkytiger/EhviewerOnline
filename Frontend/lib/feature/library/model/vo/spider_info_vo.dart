import 'json_coerce.dart';

/// 解析后的 `.ehviewer` 元数据。
class SpiderInfoVo {
  const SpiderInfoVo({
    required this.present,
    required this.version,
    required this.startPage,
    required this.previewPages,
    required this.previewPerPage,
    required this.pages,
  });

  /// 磁盘上没有可用的 `.ehviewer` 时为 false；此时 [pages] 反映实际找到的页数
  /// 而不是声明的页数。
  final bool present;
  final int version;
  final int startPage;
  final int previewPages;
  final int previewPerPage;
  final int pages;

  /// 服务端没给 `spider_info` 时的空对象：present=false 已经表达了「没有」。
  static const empty = SpiderInfoVo(
    present: false,
    version: 0,
    startPage: 0,
    previewPages: 0,
    previewPerPage: 0,
    pages: 0,
  );

  factory SpiderInfoVo.fromJson(Map<String, dynamic> json) => SpiderInfoVo(
        present: boolOr(json['present']),
        version: intOr(json['version']),
        startPage: intOr(json['start_page']),
        previewPages: intOr(json['preview_pages']),
        previewPerPage: intOr(json['preview_per_page']),
        pages: intOr(json['pages']),
      );
}
