/// 清单里的一页：这张图**是什么**，而不是它在哪。
///
/// 只记录身份（原始文件名 + 修改时间），不记录 URL 与字节数：
///
/// * URL 会随服务器地址变化，存下来只会变成过期数据；
/// * 字节数用目录实测更诚实（文件可能被系统或用户动过）。
///
/// 身份是用来**校验**的：本地第 N 个文件只有在文件名与修改时间都和当前详情一致
/// 时才会被采用。服务端重扫后页序变了、或换了服务器，同一位置就是另一张图，
/// 拿旧文件顶上会静默显示错误的画面。
class DownloadPageEntry {
  const DownloadPageEntry({required this.filename, required this.mtimeMs});

  /// 服务端给出的原始文件名。
  final String filename;

  /// 服务端给出的文件修改时间（毫秒）；0 表示未知。
  final int mtimeMs;

  /// 能否代表 [other] 这一页。
  ///
  /// 修改时间为 0（服务端没报）时退化为只比文件名：此时文件名相同就认为一致，
  /// 因为**没有更好的判据**，而拒绝所有本地副本会让下载在那种服务端上完全无效。
  bool matches(DownloadPageEntry other) {
    if (filename != other.filename) return false;
    if (mtimeMs == 0 || other.mtimeMs == 0) return true;
    return mtimeMs == other.mtimeMs;
  }

  factory DownloadPageEntry.fromJson(Map<String, dynamic> json) =>
      DownloadPageEntry(
        filename: json['filename']?.toString() ?? '',
        mtimeMs: switch (json['mtime_ms']) {
          final int value => value,
          final String value => int.tryParse(value) ?? 0,
          _ => 0,
        },
      );

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'mtime_ms': mtimeMs,
      };
}
