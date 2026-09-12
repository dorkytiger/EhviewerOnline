import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../config/app_config.dart';

/// 弹窗内容的统一排版。
///
/// forui 的 `FDialog` 只负责定位、动画与遮罩：内容边距由 builder 提供
/// （`FDialog.adaptive` 也一样，它只是按屏宽在横竖排布之间切换）。所以「标题和
/// 正文贴着边框」不是组件库的问题，而是每个 builder 都得自己加——集中在这里，
/// 就不会有的弹窗有边距、有的没有。
///
/// [children] 会自动放进可滚动区域：警告列表可能很长，让内容把弹窗撑爆会导致
/// 底部的按钮点不到。
class FDialogContent extends StatelessWidget {
  const FDialogContent({
    super.key,
    required this.title,
    this.children = const [],
    required this.actions,
  });

  final String title;
  final List<Widget> children;

  /// 右下角的操作按钮，按从左到右的顺序传入。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.typography.body.lg.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colors.foreground,
            ),
          ),
          if (children.isNotEmpty) ...[
            SizedBox(height: AppSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ],
          SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: actions,
          ),
        ],
      ),
    );
  }

  /// 一行说明文字，供 [children] 使用。
  static Widget line(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Text(
          text,
          style: context.theme.typography.body.sm.copyWith(
            color: context.theme.colors.foreground,
          ),
        ),
      );
}
