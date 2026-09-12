import '../entity/download_manifest.dart';

/// 下载管理列表里的一项：清单 + 实测占用。
///
/// 占用是**测出来的**（目录树求和）而不是清单里记的数：文件可能被系统清理、被用户
/// 或别的工具删掉，记录值与实际占用不一致时，用户需要看到的是实际占用——他们看
/// 这个数字就是为了决定删什么。所以这里不做「清单 + 统计」之外的任何加工。
class DownloadedGalleryVo {
  const DownloadedGalleryVo({required this.manifest, required this.bytes});

  final DownloadManifest manifest;

  /// 该画廊目录的实测字节数。
  final int bytes;

  int get gid => manifest.gid;

  int get pageCount => manifest.pageCount;

  bool get isComplete => manifest.isComplete;

  int get downloadedAtMs => manifest.downloadedAtMs;

  /// 列表里显示的名字。
  String get displayTitle {
    if (manifest.title.isNotEmpty) return manifest.title;
    // 清单里没有标题（旧版本写的、或被手工改过）时退回 gid：空行比编号更难用。
    return '#${manifest.gid}';
  }

  /// 封面在服务端的相对路径；空串表示没有。
  String get coverPath => manifest.coverPath;

  /// 清单里记录了几页，本机就有几页。
  ///
  /// 目录里实际有几个文件不做统计：那是阅读时的逐页校验负责的事（见
  /// `DownloadPageEntry.matches`），在列表里显示一个「12/120 页」既费一次目录遍历，
  /// 又会与真实可读性产生细微差别。
  String get statusLabel => manifest.status.label;
}
