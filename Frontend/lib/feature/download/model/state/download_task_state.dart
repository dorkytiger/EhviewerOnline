import '../../../../core/exception/global_exception.dart';
import '../../enum/download_phase.dart';

/// 下载任务的展示状态。
///
/// 不可变，所有变更产生新实例。四态齐全（未开始 / 下载中 / 完成 / 取消 / 失败），
/// 进度是派生值而不是另存的字段——两个字段各存一半进度，迟早互相矛盾。
class DownloadTaskState {
  const DownloadTaskState({
    this.gid = 0,
    this.phase = DownloadPhase.idle,
    this.done = 0,
    this.total = 0,
    this.error,
  });

  /// 任务属于哪本画廊；0 表示没有任务。
  final int gid;

  final DownloadPhase phase;

  /// 已经完成的页数（含断点续传时跳过的页）。
  final int done;

  /// 总页数；页列表还没确定时为 0。
  final int total;

  /// 失败原因；取消与成功都为 null。
  final GlobalException? error;

  /// 是否有正在进行的任务。
  bool get isRunning => phase.isRunning;

  /// 是不是这本画廊的任务。
  bool belongsTo(int other) => gid != 0 && gid == other;

  /// 进度 0..1；总数未知或还没开始时为 null，让界面显示不确定进度而不是假的 0%。
  double? get progress {
    if (total <= 0) return null;
    return (done / total).clamp(0, 1);
  }

  /// 给用户看的一行状态文案。
  String get label => switch (phase) {
        DownloadPhase.idle => '未开始',
        DownloadPhase.downloading => '下载中 $done/$total',
        DownloadPhase.success => '下载完成（共 $total 页）',
        DownloadPhase.cancelled => '已取消（已下载 $done/$total 页）',
        DownloadPhase.failed => '下载中断：${error?.message ?? '未知原因'}',
      };
}
