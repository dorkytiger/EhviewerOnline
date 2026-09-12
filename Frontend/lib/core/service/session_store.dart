import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preferences_provider.dart';

/// 会话令牌的本地存取。
///
/// Web 上会话是浏览器管理的 `HttpOnly` cookie，读不到也不需要存；本端没有
/// cookie jar，所以值存在这里并在请求时以 `Cookie` 头重放。
class SessionStore {
  const SessionStore(this._prefs);

  final SharedPreferences _prefs;

  static const String _key = 'ehw_session';

  /// 服务端下发的 cookie 名。
  static const String cookieName = 'ehw_session';

  /// 已存储的会话值，没有则为 null。
  String? read() {
    final value = _prefs.getString(_key);
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> write(String value) => _prefs.setString(_key, value);

  /// 清掉本地会话。
  ///
  /// 返回是否成功：换服务器地址时会用它判断「地址已存但会话没清掉」这种必须
  /// 如实上报的中间状态——带着上一台服务器的令牌去请求新服务器，只会得到一串
  /// 难以解释的 401。
  Future<bool> clear() => _prefs.remove(_key);
}

final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SessionStore(ref.watch(sharedPreferencesProvider)),
);
