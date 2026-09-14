import 'package:ehviewer_online/common/config/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

/// 品牌主题的行为契约。
///
/// 这里用的是**应用真实的那一份主题**（`buildBrandThemes`）：主题以前只活在 `main.dart`
/// 的私有函数里，测试各造一套 `FTheme.neutral.light.touch`，于是「主题改了什么」根本
/// 没被覆盖到——`FScaffold` 的 childPadding 归零就是踩了这个空子才漏出去的。
void main() {
  late FThemeData light;

  setUp(() {
    light = buildBrandThemes(touch: true).$1;
  });

  testWidgets('FScaffold 不再自己给内容加左右边距', (tester) async {
    // forui 的默认值：`pagePadding` 的横向部分 = 左右各 12 px。页面自己已经有留白，
    // 多这一层就是两边各一条很难看的边（真机上量到过：320 宽的手机上正文被挤到 36 px，
    // 而设计上是 24 px）。所以主题里把它归零，**且不再需要写 childPad: false**。
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const key = ValueKey('child');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, navigator) =>
            FTheme(data: light, child: navigator ?? const SizedBox.shrink()),
        home: FScaffold(child: const SizedBox.expand(key: key)),
      ),
    );
    await tester.pumpAndSettle();

    final child = tester.getRect(find.byKey(key));
    expect(child.left, 0, reason: '左边不该有 forui 塞进来的 12 px');
    expect(child.right, 400, reason: '右边同理');
  });

  testWidgets('品牌主色仍然是 EhViewer 的 teal', (tester) async {
    expect(light.colors.primary, const Color(0xFF009688));
    expect(buildBrandThemes(touch: false).$1.colors.primary, const Color(0xFF009688));
    expect(buildBrandThemes(touch: true).$2.colors.primary, const Color(0xFF4DB6AC));
  });
}
