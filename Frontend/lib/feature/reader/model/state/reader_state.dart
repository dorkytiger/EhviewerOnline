/// 阅读器的展示状态。
///
/// 刻意**不带**方向与适配模式：那两项来自 [LocalPrefs]，是跨会话的本机偏好，
/// 由 `localPrefsProvider` 单独持有并持久化。阅读器自己再存一份就成了第二处
/// 事实来源，迟早会出现「控制条显示贴合宽度、画面却是适应屏幕」。
/// 这里只放随本次阅读会话变化、并且需要被多个 widget 共享的位置状态。
///
/// 不可变：所有变更经 [copyWith] 产生新实例。
class ReaderState {
  const ReaderState({
    this.pageIndex = 0,
    this.total = 0,
    this.preloadEnabled = false,
  });

  /// 当前页在页列表里的**位置**（从 0 开始）。
  ///
  /// 存位置而不是 [PageVo.index]：页码可能有空洞，恢复进度和滑块都要用位置
  /// 寻址，跨会话保存的进度因此也只能是位置。
  final int pageIndex;

  /// 页列表长度。详情未到达时为 0。
  final int total;

  /// 是否已经可以预热相邻页（见 `ReaderService.preloadWindow`）。
  ///
  /// 独立成一个字段而不是从 [total] 推导，是为了让「详情已就绪」这件事可以被
  /// 显式 watch：预热 provider 只应该在页面数已知之后才被激活。
  final bool preloadEnabled;

  /// 是否真的有页可读。
  bool get hasPages => total > 0;

  /// 是否还有上一页。
  bool get canGoBack => pageIndex > 0;

  /// 是否还有下一页。
  bool get canGoForward => pageIndex < total - 1;

  /// 归一化后的 [pageIndex]。
  ///
  /// 总页数收缩（服务端重扫后页变少）时旧位置可能越界，所有消费方都该看这个值。
  int get clampedIndex => clampToRange(pageIndex, 0, total - 1);

  ReaderState copyWith({
    int? pageIndex,
    int? total,
    bool? preloadEnabled,
  }) {
    return ReaderState(
      pageIndex: pageIndex ?? this.pageIndex,
      total: total ?? this.total,
      preloadEnabled: preloadEnabled ?? this.preloadEnabled,
    );
  }
}

/// 把 [value] 收进 `[min, max]`。
///
/// 纯函数，供 [ReaderState.clampedIndex] 与 service 的页导航计算共用：页边界
/// 规则必须只有一处实现，否则「滑块拖到越界」与「恢复上次进度」会给出不同的
/// 结果。
///
/// [total] 为 0（详情未就绪）时 [max] 会小于 [min]，此时返回 [min]，即 0。
int clampToRange(int value, int min, int max) {
  if (max < min) return min;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}
