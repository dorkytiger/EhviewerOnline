import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
// Material 走 material_ui 而不是 flutter/material：Flutter 3.44 起 Material 已
// 从 SDK 独立成包，forui 0.26 也建立在它之上。两者是**不同的类型**，把
// flutter/material 的 ThemeData 交给 material_ui 的 MaterialApp 是类型错误。
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/route/app_route.dart';
import 'core/service/local_prefs.dart';
import 'core/service/preferences_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 在第一帧之前加载好：路由要读存储的会话线索、主题要读偏好，否则会先闪一下
  // 错误的状态。
  final preferences = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: const EhViewerOnlineApp(),
    ),
  );
}

final _routerProvider = Provider((ref) => createRouter(ref));

/// 应用根组件。
///
/// `MaterialApp.router` 是刻意保留的例外：forui 只提供组件，不提供路由宿主。
/// 主题只有一个来源——forui 的 `FThemeData` 通过 `toApproximateMaterialTheme()`
/// 派生 Material 主题，所以品牌色只在 [_brandTheme] 里定义一次。
///
/// `FTheme` / `FToaster` / `FTooltipGroup` 必须注入在 `builder` 里（也就是
/// Navigator 之上），否则被 push 出来的页面（详情、阅读器、弹窗）找不到主题。
class EhViewerOnlineApp extends ConsumerWidget {
  const EhViewerOnlineApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    final themeMode = ref.watch(localPrefsProvider.select((p) => p.themeMode));

    final (light, dark) = _buildThemes();

    return MaterialApp.router(
      title: 'EhViewer 在线库',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      themeMode: themeMode,
      theme: light.toApproximateMaterialTheme(),
      darkTheme: dark.toApproximateMaterialTheme(),
      supportedLocales: FLocalizations.supportedLocales,
      localizationsDelegates: const [...FLocalizations.localizationsDelegates],
      builder: (context, child) => FTheme(
        data: Theme.of(context).brightness == Brightness.dark ? dark : light,
        child: FToaster(child: FTooltipGroup(child: child ?? const SizedBox.shrink())),
      ),
    );
  }
}

/// 构建品牌主题（EhViewer 的 teal 绿）。
///
/// 只替换主色，其余样式从 forui 基础主题继承——这是**唯一**允许出现硬编码
/// 色值的地方，组件里再写 `Color(0xFF...)` 就失去了换肤能力。
///
/// 色值取自 EhViewer 自己的 `values/colors.xml`：`colorPrimary = teal_500
/// (#009688)`、`colorPrimaryDark = teal_700 (#00796B)`。暗色主题用提亮后的
/// teal（Material teal_300 #4DB6AC）而不是直接沿用 #009688——同一个色值在深色
/// 背景上对比度不足，主色按钮的文字会糊掉。
///
/// 触屏平台用 `.touch` 变体（控件更大），桌面用 `.desktop`。
(FThemeData, FThemeData) _buildThemes() {
  final touch = _isTouchPlatform();
  return (
    _brandTheme(
      base: touch ? FTheme.neutral.light.touch : FTheme.neutral.light.desktop,
      touch: touch,
      primary: const Color(0xFF009688),
      primaryForeground: const Color(0xFFFFFFFF),
    ),
    _brandTheme(
      base: touch ? FTheme.neutral.dark.touch : FTheme.neutral.dark.desktop,
      touch: touch,
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
}) =>
    FThemeData(
      debugLabel: 'ehviewer-brand',
      touch: touch,
      colors: base.colors.copyWith(
        primary: primary,
        primaryForeground: primaryForeground,
      ),
    );

bool _isTouchPlatform() {
  if (kIsWeb) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.macOS || TargetPlatform.linux || TargetPlatform.windows => false,
    _ => true,
  };
}
