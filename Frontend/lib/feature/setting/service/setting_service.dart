import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/result_util.dart';
import '../../auth/service/auth_service.dart';

/// setting 模块的业务用例。
///
/// 这里只承载「设置页要做的事」里**跨模块**的部分：退出登录要动 auth 的会话，
/// 这条规则换一套 UI 也照样存在，所以不能留在 viewmodel 里。
///
/// 不在这里的：
/// * 纯键值读写（主题、阅读方向、适配模式、阅读进度）由 `core/service` 承担，
///   本模块不再重复造一层 datasource/repository——两套写同一批键只会让「谁是
///   权威」变成一个问题；
/// * 修改服务器地址由 `core/service/server_address.dart` 承担，因为**登录页也要
///   用它**（未登录时路由把设置页挡在外面，那里是唯一的自救出口），而 core 的
///   配置不该被一个 feature 独占。
class SettingService {
  const SettingService(this._auth);

  final AuthService _auth;

  /// 退出登录。
  ///
  /// 由本模块转调 auth 的 service：设置页属于另一个 feature，只能依赖对方的
  /// service，不能直接碰 auth 的 provider 或 repository。
  Future<Result<void>> logout() => _auth.logout();
}

/// [SettingService] 的装配点。
final settingServiceProvider = Provider<SettingService>(
  (ref) => SettingService(ref.watch(authServiceProvider)),
);
