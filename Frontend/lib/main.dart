import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
// Material 走 material_ui 而不是 flutter/material：Flutter 3.44 起 Material 已
// 从 SDK 独立成包，forui 0.26 也建立在它之上。两者是**不同的类型**，把
// flutter/material 的 ThemeData 交给 material_ui 的 MaterialApp 是类型错误。
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'common/config/app_theme.dart';
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
/// 派生 Material 主题，所以品牌色只在 `common/config/app_theme.dart` 里定义一次。
///
/// `FTheme` / `FToaster` / `FTooltipGroup` 必须注入在 `builder` 里（也就是
/// Navigator 之上），否则被 push 出来的页面（详情、阅读器、弹窗）找不到主题。
class EhViewerOnlineApp extends ConsumerWidget {
  const EhViewerOnlineApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(_routerProvider);
    final themeMode = ref.watch(localPrefsProvider.select((p) => p.themeMode));

    final (light, dark) = buildBrandThemes();

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
