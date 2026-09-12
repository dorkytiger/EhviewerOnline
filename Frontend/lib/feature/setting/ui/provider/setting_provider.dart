import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/service/dio_provider.dart';
import '../../../../core/util/message_util.dart';
import '../../../auth/ui/provider/auth_provider.dart';
import '../../service/setting_service.dart';

/// 设置页写操作的 viewmodel：状态只有「有没有请求在飞」。
///
/// 失败不做成状态字段，而是作为方法返回值交给 view：viewmodel 不持有
/// `BuildContext`，toast 只能在 view 层弹，返回文案是这两层之间最直接的契约。
/// 主题 / 阅读方向 / 适配模式不走这里——它们是 `core/service/local_prefs.dart`
/// 的纯本地状态，同步生效，不需要三态。
class SettingController extends Notifier<bool> {
  @override
  bool build() => false;

  SettingService get _service => ref.read(settingServiceProvider);

  /// 服务器地址变化后的下游失效。
  ///
  /// 地址本身由 `common/widget/server_address_dialog.dart` 保存——登录页必须能用
  /// 同一个弹窗（未登录时设置页进不来，那里是唯一的自救出口），所以它不能住在
  /// 某个 feature 里。这里只负责「谁需要跟着变」。
  ///
  /// 只失效两个：
  /// * 客户端指向新服务器重建（它 watch 了地址，invalidate 是显式声明这个依赖，
  ///   免得以后有人把 watch 改成 read 时悄悄失去重建能力）；
  /// * auth 重新判定会话——地址变了、旧会话已清，否则路由会停在「已登录」上。
  ///
  /// library 的列表/候选集/元数据 provider 都 watch 了 auth 的状态，会由这一步
  /// 自动级联重建，所以这里不需要（也不应该）import 别的 feature 的 provider。
  void afterServerChange() {
    ref.invalidate(apiClientProvider);
    ref.invalidate(authProvider);
  }

  /// 退出登录；成功返回 null，失败返回可直接展示的中文文案。
  Future<String?> logout() async {
    state = true;
    final result = await _service.logout();
    if (!ref.mounted) {
      return null;
    }
    state = false;
    if (result.isError) {
      return messageOf(result.error);
    }

    // auth 的 service 会无条件清掉本地会话，所以这里只是让 auth 重新判定一次，
    // 路由据此把人送回登录页。
    ref.invalidate(authProvider);
    return null;
  }
}

/// 设置页写操作的 provider（地址修改、退出登录）。
final settingActionProvider =
    NotifierProvider<SettingController, bool>(SettingController.new);
