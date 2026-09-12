/// 服务端接受的排序键，附带展示文案。
enum GallerySort {
  timeDesc('time_desc', '最近添加'),
  timeAsc('time_asc', '最早添加'),
  title('title', '标题'),
  ratingDesc('rating_desc', '评分'),
  pagesDesc('pages_desc', '页数'),
  gidDesc('gid_desc', 'gid'),
  // 后端 index.SortRandom 支持；因为结果是随机顺序，分页游标对同一筛选项也
  // 不再稳定，UI 上要自行权衡是否暴露。
  random('random', '随机');

  const GallerySort(this.wire, this.label);

  /// 查询参数里真正发出去的取值。
  final String wire;

  /// 展示文案。
  final String label;
}
