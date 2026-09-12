import 'package:ehviewer_online/common/config/app_config.dart';
import 'package:ehviewer_online/common/widget/confirm_dialog.dart';
import 'package:ehviewer_online/common/widget/f_dialog_content.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

/// [confirmDialog] 的契约：三个入口（退出登录 / 删除下载 / 清空缓存）共用它，
/// 所以「有没有边距」「取消算不算放弃」这些必须在它自己这里钉住，而不是靠某个
/// feature 的用例顺带覆盖。
void main() {
  /// 按一次按钮就弹窗，并把返回值记下来。
  Future<List<bool?>> open(WidgetTester tester) async {
    final results = <bool?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, navigator) => FTheme(
          data: FTheme.neutral.light.touch,
          child: FToaster(child: navigator ?? const SizedBox.shrink()),
        ),
        home: FScaffold(
          child: Builder(
            builder: (context) => FButton(
              onPress: () async {
                results.add(await confirmDialog(
                  context,
                  title: '删除本地下载',
                  message: '将删除本机保存的 726 页。服务器上的原画廊不受影响。',
                  confirmLabel: '删除本机文件',
                ));
              },
              child: const Text('删除'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('内容有边距——forui 的 FDialog 自己不给', (tester) async {
    await open(tester);

    // 内容必须走共用的 FDialogContent；自己排一份 Column 就会顶到弹窗边框上。
    final content = find.ancestor(
      of: find.text('删除本地下载'),
      matching: find.byType(FDialogContent),
    );
    expect(content, findsOneWidget);

    final box = tester.getRect(content);
    final title = tester.getRect(find.text('删除本地下载'));
    final message = tester.getRect(find.textContaining('服务器上的原画廊'));
    expect(title.left - box.left, greaterThanOrEqualTo(AppSpacing.lg));
    expect(message.left - box.left, greaterThanOrEqualTo(AppSpacing.lg));
    expect(box.right - title.right, greaterThanOrEqualTo(AppSpacing.lg));
    // 标题在上、正文在下，且都在盒子里。
    expect(title.top, greaterThan(box.top));
    expect(message.top, greaterThan(title.bottom - 1));
  });

  testWidgets('确认返回 true，取消返回 false', (tester) async {
    final confirmed = await open(tester);
    await tester.tap(find.widgetWithText(FButton, '删除本机文件'));
    await tester.pumpAndSettle();
    expect(confirmed, [true]);

    final cancelled = await open(tester);
    await tester.tap(find.widgetWithText(FButton, '取消'));
    await tester.pumpAndSettle();
    expect(cancelled, [false]);
  });

  testWidgets('点遮罩关掉也算放弃，不会返回 null 之外的意外值', (tester) async {
    final results = await open(tester);
    // 点弹窗外的遮罩：显式取消之外的所有关闭方式都该是「没确认」。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(results, [false]);
  });
}
