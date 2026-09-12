import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/exception/global_exception.dart';
import '../../../../core/util/result_util.dart';
import '../../enum/download_outcome.dart';
import '../../enum/download_phase.dart';
import '../../model/dto/download_request_dto.dart';
import '../../model/state/download_task_state.dart';
import '../../service/download_service.dart';

/// 进行中的下载任务（运行时内存态）。
///
/// 为什么不是页面自己的状态：下载要跨越页面。用户在下载中途退回列表、再进详情页，
/// 期望看到的是「还在下、已经到 300/726」，而不是一个空白的开始按钮。放在这里，
/// 任务与进度就与页面生命周期无关。
///
/// 也刻意不落盘：「正在下载」这类瞬态信息一旦持久化，崩溃后就会留下永远停在
/// 下载中的僵尸记录。磁盘上的真实进度由清单表达（见 `DownloadManifest`）。
///
/// **同一时刻只允许一个任务。** 并行下载多本画廊只会互相抢带宽、把每个进度条都
/// 变成半速，还会让「取消」变成需要选择的东西。第二个请求会被明确拒绝。
class DownloadTaskRuntime extends Notifier<DownloadTaskState> {
  CancelToken? _token;

  @override
  DownloadTaskState build() {
    // provider 被销毁（例如测试里换容器）时取消在飞的请求，免得它继续往一个已经
    // 没人看的状态里写进度。
    ref.onDispose(() => _token?.cancel());
    return const DownloadTaskState();
  }

  /// 开始下载。
  ///
  /// 立即反馈（启动了没有 / 为什么没启动）走返回值，持续进度走 [state]：两者混在
  /// 一起就会让调用方为了拿一句「已在下载中」而必须解析状态机。
  Future<Result<void>> start(DownloadRequestDto request) async {
    if (state.isRunning) {
      return Result.error(
        const BusinessException(message: '已有下载正在进行，等它结束或先取消'),
      );
    }

    final token = CancelToken();
    _token = token;
    state = DownloadTaskState(
      gid: request.gid,
      phase: DownloadPhase.downloading,
      total: request.pages.length,
    );

    final result = await ref.read(downloadServiceProvider).download(
          request,
          cancelToken: token,
          onProgress: (done, total) {
            // 任务已被替换时不要在旧任务上继续写进度。
            if (!state.belongsTo(request.gid)) return;
            state = DownloadTaskState(
              gid: request.gid,
              phase: DownloadPhase.downloading,
              done: done,
              total: total,
            );
          },
        );
    _token = null;

    final error = result.error;
    if (error != null) {
      // 中断：页与清单都留着，重试从断点继续，所以这里只把它记为失败态。
      state = DownloadTaskState(
        gid: request.gid,
        phase: DownloadPhase.failed,
        done: state.done,
        total: state.total,
        error: error,
      );
      return Result.error(error);
    }

    final outcome = result.data ?? DownloadOutcome.completed;
    state = DownloadTaskState(
      gid: request.gid,
      phase: outcome == DownloadOutcome.completed
          ? DownloadPhase.success
          : DownloadPhase.cancelled,
      done: outcome == DownloadOutcome.completed ? state.total : state.done,
      total: state.total,
    );
    // 取消不是失败：状态里有「已取消」，调用方不需要再弹一次错误。
    return const Result.success(null);
  }

  /// 取消进行中的任务。已下载的页保留，下次可以接着下。
  void cancel() {
    if (!state.isRunning) return;
    _token?.cancel();
    state = DownloadTaskState(
      gid: state.gid,
      phase: DownloadPhase.cancelled,
      done: state.done,
      total: state.total,
    );
  }

  /// 收起已结束的任务，让界面回到「未开始」。进行中的任务不会被清掉。
  void dismiss() {
    if (state.isRunning) return;
    state = const DownloadTaskState();
  }
}

/// 任务状态的装配点。**不 autoDispose**：它要活过页面切换（理由见上）。
final downloadTaskProvider =
    NotifierProvider<DownloadTaskRuntime, DownloadTaskState>(
  DownloadTaskRuntime.new,
);
