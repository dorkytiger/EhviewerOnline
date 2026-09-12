import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../common/config/app_config.dart';
import '../exception/global_exception.dart';
import '../util/result_util.dart';
import '../util/url_util.dart';
import 'preferences_provider.dart';
import 'session_store.dart';

/// 服务器地址：可改、持久化、校验。
///
/// 编译期 `EHW_BASE_URL` 只是默认值。地址是部署细节（哪台主机、哪个端口、
/// 走隧道还是回环），改它需要重新编译会让人根本没法用别人构建的包。
///
/// 归一化与校验的实现在 `core/util/url_util.dart`——客户端也要用同一套，否则
/// 「设置里存的是什么」和「请求打到哪」会各说各话。
class ServerAddressController extends Notifier<String> {
  static const String _key = 'pref_base_url';

  @override
  String build() {
    final stored = ref.watch(sharedPreferencesProvider).getString(_key);
    return (stored == null || stored.trim().isEmpty)
        ? AppConfig.defaultBaseUrl
        : normalizeBaseUrl(stored);
  }

  /// 校验并保存新地址；**地址真的变了就清掉本地会话**。
  ///
  /// 这条不变式放在 core，而不是各入口自己记得做：会话属于某一台服务器，换
  /// 地址后继续带着旧会话，新服务器只会回 401，而那个错误看起来像「令牌错了」
  /// 而不是「地址换了」。它有两个入口——**登录页**（这里是唯一的自救出口：
  /// 未登录时路由把人挡在设置页之外，默认地址不对就彻底卡死）和设置页——分开
  /// 写迟早会漏掉一个。
  ///
  /// 只清本地、不通知服务端：旧服务器上的那个会话已经没有用了，为一个不再使用
  /// 的令牌再发一次网络请求，在地址本来就写错的情况下只会多一次失败。
  Future<Result<void>> set(String raw) async {
    final normalized = normalizeBaseUrl(raw);
    final problem = validateBaseUrl(normalized);
    if (problem != null) {
      return Result.error(problem);
    }
    // 地址没变就不清会话：点一次保存就被踢回登录页是不可接受的。
    if (normalized == state) {
      return Result.success(null);
    }

    await ref.read(sharedPreferencesProvider).setString(_key, normalized);
    final cleared = await ref.read(sessionStoreProvider).clear();
    state = normalized;

    if (!cleared) {
      return Result.error(const LocalStorageException(
        message: '地址已保存，但本地会话清除失败，请重新登录确认',
      ));
    }
    return Result.success(null);
  }
}

final serverAddressProvider =
    NotifierProvider<ServerAddressController, String>(ServerAddressController.new);
