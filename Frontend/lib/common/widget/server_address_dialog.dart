import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../core/service/server_address.dart';
import '../../core/util/message_util.dart';
import '../config/app_config.dart';
import 'f_dialog_content.dart';

/// 打开「服务器地址」编辑弹窗，返回地址是否真的变了。
///
/// 放在 `common/widget` 而不是某个 feature 里，是因为它有**两个**必须都能用的
/// 入口：设置页，以及登录页。登录页那个不是可选功能——未登录时路由把人挡在
/// 设置页之外，地址写错就彻底卡死，登录页上的这个入口是唯一的自救出口。
///
/// 用弹窗而不是页面内联编辑：被拒的地址必须报在它被输入的地方，否则用户会以为
/// 是令牌不对。保存本身走 `core` 的 `serverAddressProvider`，它负责校验、归一化
/// 以及「地址变了就清掉本地会话」这条不变式。
Future<bool> showServerAddressDialog(
  BuildContext context, {
  required String initial,
}) async {
  final changed = await showFDialog<bool>(
    context: context,
    builder: (context, style, animation) => FDialog.adaptive(
      horizontalBuilder: (context, style) =>
          _AddressDialog(initial: initial),
      verticalBuilder: (context, style) => _AddressDialog(initial: initial),
    ),
  );
  return changed ?? false;
}

/// 地址编辑弹窗的内容。
///
/// 初值由外部传入而不是自己去读 provider：这样 `initState` 里不需要碰 `ref`，
/// 输入框从打开那一刻就是定值，不会在保存成功、地址变化之后又被重建成新值。
class _AddressDialog extends ConsumerStatefulWidget {
  const _AddressDialog({required this.initial});

  final String initial;

  @override
  ConsumerState<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends ConsumerState<_AddressDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 用户一改输入就收回上一轮的错误：错误一直挂着，会让人以为新输入也是错的。
    _controller.addListener(_clearError);
  }

  void _clearError() {
    if (_error == null) return;
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _controller.removeListener(_clearError);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    final previous = ref.read(serverAddressProvider);
    final result = await ref.read(serverAddressProvider.notifier).set(_controller.text);
    if (!mounted) return;

    if (result.isError) {
      setState(() {
        _saving = false;
        _error = messageOf(result.error);
      });
      return;
    }

    final changed = ref.read(serverAddressProvider) != previous;
    // 返回给调用方，让它失效自己那部分依赖地址的 provider——弹窗属于 common，
    // 不该知道有哪些 feature 关心这件事。
    Navigator.of(context).pop(changed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return FDialogContent(
      title: '服务器地址',
      actions: [
        FButton(
          variant: FButtonVariant.outline,
          onPress: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        SizedBox(width: AppSpacing.sm),
        FButton(
          onPress: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
      children: [
        Text(
          '修改后会清除当前会话，需要在新服务器上重新输入访问令牌。',
          style: theme.typography.body.sm.copyWith(
            color: theme.colors.mutedForeground,
          ),
        ),
        SizedBox(height: AppSpacing.md),
        FTextFormField(
          control: FTextFieldControl.managed(controller: _controller),
          label: const Text('地址'),
          hint: 'http://127.0.0.1:8080',
          autofocus: true,
          enabled: !_saving,
          forceErrorText: _error,
          onSubmit: (_) => _save(),
        ),
      ],
    );
  }
}
