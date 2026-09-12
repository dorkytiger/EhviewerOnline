import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../../../common/config/app_config.dart';
import '../../../../common/widget/server_address_dialog.dart';
import '../../../../core/service/dio_provider.dart';
import '../provider/auth_provider.dart';

/// 登录页。
///
/// 令牌是唯一凭据，所以这一页只有一件事要做。它必须写清**令牌会发到哪台服务器**：
/// 在错误的部署上敲令牌只会得到「令牌无效」，那会把人引向怀疑令牌，而真正的问题
/// 是地址。因此地址取自 [apiClientProvider]（客户端真正在用的值），而不是编译期
/// 默认值——两者可以不同（测试或多服务器构建会注入别的客户端），显示编译进去的
/// 那个只会让人去排查一台没被使用的服务器。
class LoginView extends ConsumerStatefulWidget {
  const LoginView({super.key});

  @override
  ConsumerState<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends ConsumerState<LoginView> {
  /// 表单在宽屏上的最大宽度。
  ///
  /// forui 没有这个 token：它管的是可读行宽而不是间距/圆角刻度，所以用具名常量
  /// 表达意图，而不是就地写一个没有来历的裸数字。
  static const double _formMaxWidth = 420;

  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    await ref.read(authProvider.notifier).login(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final auth = ref.watch(authProvider);
    final busy = auth.submitting;

    return FScaffold(
      child: Center(
        child: SingleChildScrollView(
          padding: theme.style.pagePadding,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _formMaxWidth),
            child: FCard(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      FLucideIcons.lock,
                      size: AppIcon.lg,
                      color: theme.colors.primary,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      'EhViewer 在线库',
                      textAlign: TextAlign.center,
                      style: theme.typography.body.xl.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colors.foreground,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '请输入访问令牌',
                      textAlign: TextAlign.center,
                      style: theme.typography.body.sm.copyWith(
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    // FTextField.password 自带可见性切换，所以这里不需要本地
                    // obscure 状态去跟组件同步。
                    FTextField.password(
                      control: FTextFieldControl.managed(
                        controller: _controller,
                      ),
                      label: const Text('访问令牌'),
                      hint: '由 ehviewer-webd gentoken 生成',
                      autofocus: true,
                      enabled: !busy,
                      onSubmit: (_) => _submit(),
                    ),
                    if (auth.error != null) ...[
                      const SizedBox(height: AppSpacing.lg),
                      _LoginError(message: auth.error!),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    FButton(
                      // 提交期间禁用，用按钮自身状态挡住重复提交，而不是靠表单外
                      // 的守卫去猜。
                      onPress: busy ? null : _submit,
                      prefix: busy
                          ? const FCircularProgress(
                              size: FCircularProgressSizeVariant.sm,
                            )
                          : const Icon(FLucideIcons.logIn, size: AppIcon.sm),
                      child: Text(busy ? '正在验证…' : '登录'),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    const FDivider(),
                    const SizedBox(height: AppSpacing.md),
                    _ServerInfo(baseUrl: ref.watch(apiClientProvider).baseUrl),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 页内错误提示块。
///
/// 用页内提示而不是 toast：登录失败时错误必须留在屏幕上、和输入框挨着，用户才能
/// 一边看原因一边改令牌；toast 会自己消失，还会盖住别的内容。
class _LoginError extends StatelessWidget {
  const _LoginError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colors.error,
        borderRadius: theme.style.borderRadius.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            FLucideIcons.circleAlert,
            size: AppIcon.sm,
            color: theme.colors.errorForeground,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.errorForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 当前会话将要发往的服务器地址，**可以就地修改**。
///
/// 这是未登录状态下唯一的自救出口：路由在未认证时把设置页挡在外面，所以当地址
/// 不对（自建服务、走隧道、局域网 IP）时，这里是唯一能改它的地方。把它放在登录
/// 页不是"顺手加的功能"——没有它，默认地址不对就等于应用完全不可用。
class _ServerInfo extends ConsumerWidget {
  const _ServerInfo({required this.baseUrl});

  final String baseUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          FLucideIcons.server,
          size: AppIcon.sm,
          color: theme.colors.mutedForeground,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '服务器',
                style: theme.typography.body.xs.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                baseUrl,
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        // 用带文字的按钮而不是一个铅笔图标：一个光秃秃的图标很难被发现，而恰恰
        // 是「找不到改地址的地方」让用户卡在这里。
        FButton(
          variant: FButtonVariant.ghost,
          onPress: () => _edit(context, ref),
          prefix: const Icon(FLucideIcons.pencil, size: AppIcon.sm),
          child: const Text('修改'),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final changed = await showServerAddressDialog(context, initial: baseUrl);
    if (!changed) return;
    // 会话属于上一台服务器，地址变了就得重新判定一次；auth 是登录页自己的
    // feature，所以这里失效它是允许的（弹窗在 common，不负责知道这些）。
    ref.invalidate(authProvider);
  }
}
