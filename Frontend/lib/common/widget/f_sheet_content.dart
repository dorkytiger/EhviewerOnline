import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../../common/config/app_config.dart';

/// 底部面板内容的统一排版。
///
/// 面板里的标题/副标题/拖拽条如果在每个 `showFSheet` 里各写一遍，很快会长出
/// 互不相同的字号与间距；集中在这里，一处定义多处复用。
class FSheetContent extends StatelessWidget {
  const FSheetContent({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    // **面板背景必须由内容自己画。** forui 的 `FSheet` 只负责定位、进出场动画、
    // 拖拽手势与安全区，它的 build 里没有任何背景绘制（`FModalSheetStyle` 也只有
    // 屏障与动画字段）。builder 返回的如果只是一个 Padding，面板就是透明的——
    // 底下的列表会直接透上来。
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colors.background,
        border: Border(top: BorderSide(color: theme.colors.border)),
        // 只有上面两个角需要圆角：面板从底部升上来，下面贴着屏幕边缘。
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.lg),
        ),
      ),
      padding: theme.style.pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: titleText(context, title)),
              ?trailing,
            ],
          ),
          if (subtitle != null) ...[
            SizedBox(height: AppSpacing.xs),
            subtitleText(context, subtitle!),
          ],
          SizedBox(height: AppSpacing.lg),
          Flexible(child: child),
        ],
      ),
    );
  }

  static Widget titleText(BuildContext context, String text) => Text(
        text,
        style: context.theme.typography.body.xl.copyWith(
          fontWeight: FontWeight.w600,
          color: context.theme.colors.foreground,
        ),
      );

  static Widget subtitleText(BuildContext context, String text) => Text(
        text,
        style: context.theme.typography.body.sm.copyWith(
          color: context.theme.colors.mutedForeground,
        ),
      );

  /// 面板顶部的拖拽条。
  static Widget drag(BuildContext context) => Center(
        child: Container(
          width: context.theme.style.sizes.tile,
          height: AppSpacing.xs,
          decoration: BoxDecoration(
            color: context.theme.colors.border,
            borderRadius: BorderRadius.circular(AppSpacing.xs),
          ),
        ),
      );
}
