import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../../common/config/app_config.dart';
import '../../core/util/message_util.dart';

/// 查询失败时的统一错误视图。
///
/// 规范要求错误视图必须带**可执行信息 + 重试入口**：只显示一行红字等于让
/// 用户自己想办法。[onRetry] 为空时只说明情况，但仍然给出原因。
class CustomErrorWidget extends StatelessWidget {
  const CustomErrorWidget({
    super.key,
    required this.error,
    this.onRetry,
    this.retryLabel = '重试',
  });

  /// 任意错误对象，经 [messageOf] 统一取文案。
  final Object? error;

  /// 重试回调；为空时不显示按钮。
  final VoidCallback? onRetry;

  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final padding = theme.style.pagePadding;

    return Center(
      child: SingleChildScrollView(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              FLucideIcons.circleAlert,
              size: theme.style.sizes.field.lg,
              color: theme.colors.error,
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              '加载失败',
              style: theme.typography.body.lg.copyWith(
                color: theme.colors.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: AppSpacing.xs),
            Text(
              messageOf(error),
              textAlign: TextAlign.center,
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
            if (onRetry != null) ...[
              SizedBox(height: AppSpacing.lg),
              FButton(
                onPress: onRetry,
                prefix: const Icon(FLucideIcons.refreshCw, size: AppIcon.sm),
                child: Text(retryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
