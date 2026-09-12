import 'json_coerce.dart';

/// 画廊里的一张图片。
class PageVo {
  const PageVo({
    required this.index,
    required this.filename,
    required this.ext,
    required this.size,
    required this.mtimeMs,
    required this.url,
  });

  final int index;
  final String filename;
  final String ext;
  final int size;
  final int mtimeMs;

  /// 服务端相对 URL，例如 `/img/1234567/0`。
  final String url;

  factory PageVo.fromJson(Map<String, dynamic> json) => PageVo(
        index: intOr(json['index']),
        filename: stringOr(json['filename']),
        ext: stringOr(json['ext']),
        size: intOr(json['size']),
        mtimeMs: intOr(json['mtime_ms']),
        url: stringOr(json['url']),
      );
}
