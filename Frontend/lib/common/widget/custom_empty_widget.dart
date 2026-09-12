import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../../common/config/app_config.dart';

/// 查询成功但没有数据时的统一空状态。
class CustomEmptyWidget extends StatelessWidget {
  const CustomEmptyWidget({
    super.key,
    this.icon,
    this.message = '这里还没有内容',
    this.hint,
  });

  final IconData? icon;
  final String message;

  /// 可选的一行补充说明，用来告诉用户下一步能做什么。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;

    return Center(
      child: Padding(
        padding: theme.style.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? FLucideIcons.inbox,
              size: theme.style.sizes.field.lg,
              color: theme.colors.mutedForeground,
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.typography.body.md.copyWith(
                color: theme.colors.foreground,
              ),
            ),
            if (hint != null) ...[
              SizedBox(height: AppSpacing.xs),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
