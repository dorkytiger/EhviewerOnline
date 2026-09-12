import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/exception/global_exception.dart';
import '../../../../core/service/dio_provider.dart';
import '../../../../core/service/sse_client.dart';
import '../../../auth/ui/provider/auth_provider.dart';
import '../../model/vo/index_changed_event_vo.dart';
import 'facets_provider.dart';
import 'gallery_detail_provider.dart';
import 'library_list_provider.dart';
import 'server_meta_provider.dart';

/// 事件流当前是否连着。
enum LiveStatus {
  connecting,
  live,

  /// 服务端明确说没有事件中心，或连接失败。
  unavailable,
}

/// 订阅 `/api/v1/events`，并把索引变化反映到界面上。
///
/// 这是把后端的文件监听变成用户能看见的东西：没有它，只剩下轮询（把隧道预算
/// 花在空响应上）或者一个悄悄变旧的库。
///
/// 这个 provider 是「被 watch 才连」的：没有监听者就不建立连接，最后一个监听
/// 者离开时连接被释放。
class LiveUpdatesNotifier extends Notifier<LiveStatus> {
  CancelToken? _cancel;

  @override
  LiveStatus build() {
    // 会话变化要重连：流是带会话的。
    ref.watch(authProvider.select((s) => s.status));

    final meta = ref.watch(serverMetaProvider).value;
    if (meta != null && !meta.supportsSse) {
      // 服务端说它没有事件中心。如实上报，而不是假装在连接——否则界面会显示
      // 一个永远不动的加载态。
      return LiveStatus.unavailable;
    }

    _cancel?.cancel();
    final cancel = CancelToken();
    _cancel = cancel;
    ref.onDispose(() {
      cancel.cancel();
      if (identical(_cancel, cancel)) _cancel = null;
    });

    unawaited(_listen(cancel));
    return LiveStatus.connecting;
  }

  Future<void> _listen(CancelToken cancel) async {
    final client = ref.read(apiClientProvider);
    try {
      await for (final event in client.streamEvents(cancelToken: cancel)) {
        if (!ref.mounted) return;
        switch (event.name) {
          case EventName.hello:
            // 服务端立刻发这个，客户端靠它区分「流是通的」和「被缓冲代理吞了」。
            state = LiveStatus.live;
          case EventName.indexChanged:
            state = LiveStatus.live;
            _applyIndexChange(event.data);
          default:
            break;
        }
      }
    } on GlobalException {
      if (!ref.mounted) return;
      state = LiveStatus.unavailable;
    }
  }

  void _applyIndexChange(String data) {
    IndexChangedEventVo change;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return;
      change = IndexChangedEventVo.fromJson(decoded);
    } on FormatException {
      // 一条负载格式不对，不值得为此把流拆掉；下一个事件很快就到。
      return;
    }

    // 列表只重取第一页并镜像（保住用户的滚动位置），所以放在最前面：无论下面
    // 走哪条分支，列表都要更新。
    unawaited(ref.read(galleryListProvider.notifier).applyLiveChange());

    // 被截断的增量意味着 id 列表不完整，不能当作全量来套用。
    if (change.truncated) {
      ref.invalidate(facetsProvider);
      return;
    }

    // 元数据变化更罕见，而且会改变候选计数，值得重取。
    final previous = ref.read(serverMetaProvider).value;
    if (previous == null || change.snapshotAtMs != previous.snapshotAtMs) {
      ref.invalidate(facetsProvider);
      ref.invalidate(serverMetaProvider);
    }

    // 只有变化过的画廊详情需要重取，没动过的保持缓存。
    for (final gid in change.affected) {
      ref.invalidate(galleryDetailProvider(gid));
    }
  }
}

final liveUpdatesProvider =
    NotifierProvider<LiveUpdatesNotifier, LiveStatus>(LiveUpdatesNotifier.new);
