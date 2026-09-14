/// 品牌主题。这是**唯一**允许出现硬编码色值的地方。
///
/// 放在 `common/config` 而不是 `main.dart`：主题是全局配置，而且测试要能拿到**真实的
/// 那一份**去验证它（`test/app_theme_test.dart`），不能各造一套。
///
/// 只替换主色与一处 scaffold 行为，其余样式从 forui 基础主题继承——组件里再写
/// `Color(0xFF...)` 就失去了换肤能力。
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

/// 构建亮/暗两套品牌主题（EhViewer 的 teal 绿）。
///
/// 色值取自 EhViewer 自己的 `values/colors.xml`：`colorPrimary = teal_500 (#009688)`、
/// `colorPrimaryDark = teal_700 (#00796B)`。暗色主题用提亮后的 teal（Material teal_300
/// #4DB6AC）而不是直接沿用 #009688——同一个色值在深色背景上对比度不足，主色按钮的
/// 文字会糊掉。
///
/// 触屏平台用 `.touch` 变体（控件更大），桌面用 `.desktop`。[touch] 显式给出时以它
/// 为准——测试要的是确定的变体，不能随宿主平台变。
(FThemeData, FThemeData) buildBrandThemes({bool? touch}) {
  final useTouch = touch ?? isTouchPlatform();
  return (
    _brandTheme(
      base: useTouch ? FTheme.neutral.light.touch : FTheme.neutral.light.desktop,
      touch: useTouch,
      primary: const Color(0xFF009688),
      primaryForeground: const Color(0xFFFFFFFF),
    ),
    _brandTheme(
      base: useTouch ? FTheme.neutral.dark.touch : FTheme.neutral.dark.desktop,
      touch: useTouch,
      primary: const Color(0xFF4DB6AC),
      primaryForeground: const Color(0xFF00251F),
    ),
  );
}

FThemeData _brandTheme({
  required FThemeData base,
  required bool touch,
  required Color primary,
  required Color primaryForeground,
}) {
  final colors = base.colors.copyWith(
    primary: primary,
    primaryForeground: primaryForeground,
  );

  return FThemeData(
    debugLabel: 'ehviewer-brand',
    touch: touch,
    colors: colors,
    // **把 FScaffold 默认给 child 的左右各 12 px 归零。**
    //
    // forui 的 `FScaffoldStyle.childPadding` 默认是 `pagePadding` 的横向部分
    // （`EdgeInsets.symmetric(vertical: 8, horizontal: 12)`，只取左右），也就是说
    // 不写 `childPad: false` 的话，每个页面的内容都会在**自己那层留白之外**再被挤进
    // 12 px。所有页面都已经自己控制留白，多出来的这 12 px 就是两边各一条很难看的边
    // （详情页实测：正文左边缘在 320 宽的手机上是 36 px，而不是设计上的 24 px）。
    //
    // 在主题里一次归零，页面就不用逐个写 `childPad: false`，新页面也不会忘。
    // `childPadding` 在 forui 里只被 `FScaffold` 的那一个 `Padding` 用到，改它不会
    // 影响布局计算。
    scaffoldStyle: FScaffoldStyle.inherit(colors: colors, style: base.style)
        .copyWith(childPadding: EdgeInsetsGeometryDelta.value(EdgeInsets.zero)),
  );
}

/// 触屏平台判定：Web 一律按触屏（浏览器多半在手机上打开），桌面三平台按桌面。
bool isTouchPlatform() {
  if (kIsWeb) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.linux || TargetPlatform.windows =>
      false,
    _ => true,
  };
}
