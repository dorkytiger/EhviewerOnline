import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

import '../../common/config/app_config.dart';
import '../../feature/auth/model/state/auth_state.dart';
import '../../feature/auth/ui/provider/auth_provider.dart';
import '../../feature/auth/ui/view/login_view.dart';
import '../../feature/download/ui/view/download_view.dart';
import '../../feature/download/ui/view/gallery_download_view.dart';
import '../../feature/library/ui/view/gallery_detail_view.dart';
import '../../feature/library/ui/view/library_view.dart';
import '../../feature/main/ui/view/app_shell_view.dart';
import '../../feature/reader/ui/view/reader_view.dart';
import '../../feature/setting/ui/view/setting_view.dart';

/// 构建应用路由。
///
/// 重定向由 [authProvider] 驱动：任何请求拿到 401 都会把人送到登录页，而不是
/// 停在一个静默显示空内容的页面上。会话还在校验时（[AuthStatus.checking]）
/// 保持原地不动——每次冷启动都闪一下登录页比短暂停留更糟。
///
/// **进入详情 / 下载 / 阅读器一律用 `push`，不要用 `go`。** 这三条路由不在
/// [StatefulShellRoute] 里，`go` 会把整个栈换成「只有这一页」——下面什么都没有，
/// 于是 Android 的侧边滑动返回（系统返回手势）直接把应用退到桌面，iOS 的滑动返回
/// 也一起失效。`go` 只留给真正的「换掉当前位置」：登录成功回图库、兜底页回首页。
GoRouter createRouter(Ref ref) {
  return GoRouter(
    initialLocation: '/',
    refreshListenable: _AuthListenable(ref),
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final loggingIn = state.matchedLocation == '/login';

      if (auth.isChecking) {
        // 会话校验在飞行中，保持当前位置。
        return null;
      }
      if (!auth.isAuthenticated) {
        return loggingIn ? null : '/login';
      }
      if (loggingIn) {
        return '/';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const LoginView()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShellView(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/', builder: (context, state) => const LibraryView()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/downloads',
                builder: (context, state) => const DownloadView(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingView(),
              ),
            ],
          ),
        ],
      ),
      // 详情、下载页、阅读器在 shell 之外，这样它们会盖住底部导航栏——阅读时就该
      // 如此。三个页面**平级**挂在这里，而不是互相嵌套的子路由：用 `push` 进入一个
      // 子路由时，go_router 会把它的父路由页面也一起压栈，于是从阅读器返回会先回到
      // 一个一模一样的详情页（看起来像「返回没反应」）。平级之后一次 push 只加一个
      // 页面。
      GoRoute(
        path: '/gallery/:gid',
        builder: (context, state) => GalleryDetailView(
          gid: int.tryParse(state.pathParameters['gid'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: '/gallery/:gid/download',
        builder: (context, state) => GalleryDownloadView(
          gid: int.tryParse(state.pathParameters['gid'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: '/gallery/:gid/read',
        builder: (context, state) => ReaderView(
          gid: int.tryParse(state.pathParameters['gid'] ?? '') ?? 0,
          initialPage: int.tryParse(state.uri.queryParameters['page'] ?? '') ?? 0,
        ),
      ),
    ],
    errorBuilder: (context, state) => _NotFoundView(location: state.uri.toString()),
  );
}

/// 把 Riverpod 的通知桥接成 [GoRouter] 的 listenable，会话在页面停留期间失效
/// 也能触发重定向。
class _AuthListenable extends ChangeNotifier {
  _AuthListenable(this._ref) {
    _subscription = _ref.listen<AuthState>(
      authProvider,
      (previous, next) {
        if (previous?.status != next.status) notifyListeners();
      },
    );
  }

  final Ref _ref;
  late final ProviderSubscription<AuthState> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}

/// 地址写错时的兜底页。
///
/// 它必须显示用户实际输入的地址：这是唯一能让人看出「多打了一个字符」还是
/// 「路由没配」的地方。
class _NotFoundView extends StatelessWidget {
  const _NotFoundView({required this.location});

  final String location;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return FScaffold(
      header: FHeader(
        title: const Text('页面不存在'),
        suffixes: [
          FHeaderAction(
            icon: const Icon(FLucideIcons.house),
            onPress: () => context.go('/'),
          ),
        ],
      ),
      child: Center(
        child: Padding(
          padding: theme.style.pagePadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                FLucideIcons.compass,
                size: AppIcon.lg,
                color: theme.colors.mutedForeground,
              ),
              SizedBox(height: AppSpacing.md),
              Text('没有这个地址', style: theme.typography.body.lg),
              SizedBox(height: AppSpacing.xs),
              Text(
                location,
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
              SizedBox(height: AppSpacing.lg),
              FButton(
                onPress: () => context.go('/'),
                child: const Text('回到图库'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
