/// 一次下载任务所处的阶段。
///
/// 与 [DownloadStatus] 的分工：本枚举描述**内存里的任务**，只在应用运行期间存在；
/// 那个描述**磁盘上的结果**，重启之后仍在。两者不能互相替代——用任务阶段去表示
/// 「已下载」，重启后就没有任何东西能回答这个问题。
enum DownloadPhase {
  /// 没有任务。
  idle('未开始'),

  /// 已确定页列表，正在逐页取图。
  downloading('下载中'),

  /// 全部页写完。
  success('已完成'),

  /// 用户取消：不是错误，但也没有完成。
  cancelled('已取消'),

  /// 出错中断。页文件与清单都保留，重试可以从断点继续。
  failed('已中断');

  const DownloadPhase(this.label);

  /// 面向用户的文案。
  final String label;

  /// 是否正在跑（此时界面要显示进度并禁用重复触发）。
  bool get isRunning => this == DownloadPhase.downloading;
}
