import '../entity/download_page_entry.dart';

/// 一页的地址与身份，跨层传递下载相关操作的入参。
///
/// 四件事必须一起走：位置（本地文件名由它决定）、原始文件名与修改时间（校验本地
/// 副本是否仍然对应当前详情）、URL（回源时的相对路径）。拆成多个参数就会有人
/// 少传一个，而少传 [filename] 的后果是静默读到别的图。
class DownloadPageDto {
  const DownloadPageDto({
    required this.position,
    required this.filename,
    required this.mtimeMs,
    required this.url,
  });

  /// 页在列表里的位置（从 0 开始）。与 `PageVo.index` 不是一回事：页码可能有空洞。
  final int position;

  final String filename;

  final int mtimeMs;

  /// 服务端相对路径，例如 `/img/1234567/0`。绝对地址由数据层拼（见
  /// `DownloadRemoteDatasource`）。
  final String url;

  /// 这一页在清单里的身份记录。
  DownloadPageEntry get entry =>
      DownloadPageEntry(filename: filename, mtimeMs: mtimeMs);
}
