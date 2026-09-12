/// 服务端上报的异常码，附带可读描述。
///
/// 服务端只发原始 code，文案放在这里，这样翻译和措辞调整不需要发服务端版本。
/// **未知 code 原样展示**而不是隐藏：更新的服务端不能让一个问题在界面上消失。
class GalleryAnomaly {
  const GalleryAnomaly(this.code);

  final String code;

  static const pageCountMismatch = 'page_count_mismatch';
  static const pageGap = 'page_gap';
  static const emptyGallery = 'empty_gallery';
  static const gidMismatch = 'gid_mismatch';
  static const dirUnparsable = 'dir_unparsable';
  static const spiderInfoInvalid = 'spiderinfo_invalid';
  static const spiderInfoMissing = 'spiderinfo_missing';

  /// 可读描述；无对应文案时返回原始 code。
  String get description => switch (code) {
        pageCountMismatch => '页数与元数据不一致',
        pageGap => '页码不连续',
        emptyGallery => '目录内没有图片',
        gidMismatch => '目录名与元数据中的 gid 不一致',
        dirUnparsable => '目录名不符合 <gid>-<标题>',
        spiderInfoInvalid => '元数据文件无法解析',
        spiderInfoMissing => '缺少元数据文件',
        _ => code,
      };

  /// 是否值得打断阅读器。
  ///
  /// 缺少元数据文件只是观感问题，画廊仍能正常阅读；页码不连续不是——阅读时
  /// 会跳页。
  bool get isSevere =>
      code == pageGap || code == emptyGallery || code == gidMismatch;
}
