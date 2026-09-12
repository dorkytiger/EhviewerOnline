import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../config/app_config.dart';
import 'f_dialog_content.dart';

/// 危险操作的二次确认。
///
/// 只有明确点确认才返回 true：取消、点遮罩、返回手势都算放弃。放在 `common` 是因为
/// 退出登录、删除下载、清空缓存都要用它——每个 feature 各写一份的结果是有的弹窗
/// 有取消按钮、有的没有，而用户对「危险操作」的预期必须一致。
///
/// 文案由调用方给全：确认对话框无法自己知道「删掉之后会发生什么」，而后果正是用户
/// 做决定所需的信息。
///
/// **边距由 [FDialogContent] 给**：forui 的 `FDialog` 只负责定位、动画与遮罩，内容
/// 贴着边框是每个 builder 自己的事。这里曾经自己排了一份没有 padding 的 Column，
/// 结果三个入口（退出登录 / 删除下载 / 清空缓存）的弹窗全都顶到边框上。
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final content = FDialogContent(
    title: title,
    actions: [
      FButton(
        variant: FButtonVariant.outline,
        onPress: () => Navigator.of(context).pop(false),
        child: const Text('取消'),
      ),
      SizedBox(width: AppSpacing.sm),
      FButton(
        variant: FButtonVariant.destructive,
        onPress: () => Navigator.of(context).pop(true),
        child: Text(confirmLabel),
      ),
    ],
    children: [FDialogContent.line(context, message)],
  );

  final confirmed = await showFDialog<bool>(
    context: context,
    builder: (context, style, animation) => FDialog.adaptive(
      // 内容只有一段文字和两个按钮，横竖两种布局没有区别；显式给同一份，而不是
      // 硬造两套会走样的排版。
      horizontalBuilder: (context, style) => content,
      verticalBuilder: (context, style) => content,
    ),
  );
  return confirmed ?? false;
}
