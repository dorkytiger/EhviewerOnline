import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ehviewer_online/core/exception/global_exception.dart';
import 'package:ehviewer_online/core/route/app_route.dart';
import 'package:ehviewer_online/core/service/api_client.dart';
import 'package:ehviewer_online/core/service/dio_provider.dart';
import 'package:ehviewer_online/core/service/file_store.dart';
import 'package:ehviewer_online/core/service/preferences_provider.dart';
import 'package:ehviewer_online/core/service/session_store.dart';
import 'package:ehviewer_online/core/service/sse_client.dart';
import 'package:ehviewer_online/core/util/result_util.dart';
import 'package:ehviewer_online/feature/download/ui/widget/downloaded_gallery_tile.dart';
import 'package:ehviewer_online/feature/library/ui/widget/gallery_card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_file_store.dart';

/// 导航栈的不变式：**进入详情 / 下载 / 阅读器之后，它们下面必须有东西**。
///
/// 这条测试来自真机反馈：详情页上从屏幕侧边滑动返回，应用「退出到桌面」——Android
/// 的系统返回手势会弹掉最上面那条路由，而这三条路由当时是用 `go` 进去的：`go` 把
/// 整个栈换成「只有这一页」，弹出主路由就等于退出应用，iOS 的滑动返回也一起失效。
///
/// 所以这里不看具体界面，只钉住栈的形状：从图库进去之后 `canPop()` 必须为真，
/// 而且返回要按顺序回到图库。
///
/// `createRouter` 要的是一个活在容器里的 `Ref`，而且 `router.state` 只有在路由被挂
/// 到 widget 树上之后才有值，所以这里真的把 app 的根 widget 搭起来（数据都走桩，
/// 不碰网络）。
void main() {
  late ProviderContainer container;
  late GoRouter router;

  Future<void> pumpApp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      // 关掉 Riverpod 3 的自动重试：桩服务端对详情请求一律报错，重试会留下定时器，
      // 而这条测试只关心导航栈的形状。
      retry: (retryCount, error) => null,
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        // 会话语义：服务端说「已登录」，于是导航一路放行而不是被重定向到登录页。
        apiClientProvider.overrideWithValue(_StubApiClient(prefs)),
        // 阅读器在详情失败时会退到本地副本，那条路要碰 `path_provider`；真实平台通道
        // 在假时钟里永远不会返回，会让 pumpAndSettle 一直等下去。
        fileStoreProvider.overrideWithValue(MemoryFileStore()),
      ],
    );
    router = container.read(_routerProvider);
    addTearDown(container.dispose);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: ThemeData(useMaterial3: true),
          routerConfig: router,
          builder: (context, child) => FTheme(
            data: FTheme.neutral.light.touch,
            child: FToaster(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 前置条件：停在图库，且下面确实没有东西。
  void expectAtLibraryRoot() {
    expect(router.state.matchedLocation, '/');
    expect(router.canPop(), isFalse, reason: '图库是根页面，下面不该有东西');
  }

  for (final location in const [
    '/gallery/1000001',
    '/gallery/1000001/download',
    '/gallery/1000001/read',
    '/gallery/1000001/read?page=3',
  ]) {
    testWidgets('$location 下面留着图库，返回手势回到图库而不是退出应用', (tester) async {
      await pumpApp(tester);
      expectAtLibraryRoot();

      router.push(location);
      await tester.pumpAndSettle();

      // 用 uri 而不是 matchedLocation：后者只有路径，查询参数（?page=3）会丢。
      expect(router.state.uri.toString(), location);
      expect(
        router.canPop(),
        isTrue,
        reason: '下面没有页面时，系统返回手势会把应用退到桌面',
      );

      router.pop();
      await tester.pumpAndSettle();
      expect(router.state.matchedLocation, '/');
    });
  }

  testWidgets('从图库点进详情用的是 push：详情页下面留着图库', (tester) async {
    await pumpApp(tester);

    // 走真实的调用点（画廊磁贴的 onTap），而不是 test 里自己 push——`go` 与 `push`
    // 的区别只有调用点才知道，自己 push 就测不出调用点写错。
    expect(find.byType(GalleryCard), findsOneWidget);
    await tester.tap(find.byType(GalleryCard));
    await tester.pumpAndSettle();

    expect(router.state.uri.toString(), '/gallery/1000001');
    expect(router.canPop(), isTrue, reason: '调用点写成 go 的话这里会是 false');

    router.pop();
    await tester.pumpAndSettle();
    expect(router.state.matchedLocation, '/');
  });

  testWidgets('从「下载」页点开阅读器：下面留着下载页（离线路径）', (tester) async {
    await pumpApp(tester);
    // 造一条已下载记录：下载管理页只认本地清单，不碰服务器。
    final store = container.read(fileStoreProvider) as MemoryFileStore;
    await store.write(
      '/support/downloads/7/manifest.json',
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'gid': 7,
            'title': '本机画廊',
            'cover_path': '',
            'status': 'complete',
            'downloaded_at_ms': 1,
            'pages': [
              {'filename': '001.jpg', 'mtime_ms': 1},
            ],
          }),
        ),
      ),
    );

    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(router.state.matchedLocation, '/downloads');

    await tester.tap(find.byType(DownloadedGalleryTile));
    await tester.pumpAndSettle();

    expect(router.state.uri.toString(), '/gallery/7/read');
    expect(router.canPop(), isTrue, reason: '调用点写成 go 的话这里会是 false');

    router.pop();
    await tester.pumpAndSettle();
    expect(router.state.matchedLocation, '/downloads');
  });

  testWidgets('阅读器与下载页不嵌套在详情页之下（否则 push 会把详情页重复压栈）', (tester) async {
    await pumpApp(tester);

    router.push('/gallery/1000001');
    await tester.pumpAndSettle();
    router.push('/gallery/1000001/read');
    await tester.pumpAndSettle();

    // 栈：图库 → 详情 → 阅读器。pop 两次就该回到图库；多一次都说明中间多压了一个
    // 一模一样的详情页（那会让「返回」看起来没反应）。
    final seen = <String>[];
    while (router.canPop()) {
      router.pop();
      await tester.pumpAndSettle();
      seen.add(router.state.matchedLocation);
    }
    expect(seen, ['/gallery/1000001', '/']);
  });
}

/// 与 `main.dart` 里同名的装配点。
final _routerProvider = Provider<GoRouter>((ref) => createRouter(ref));

/// 只回答会话校验与图库列表、其余一律报错的客户端：让导航测试完全不碰 HTTP。
class _StubApiClient extends ApiClient {
  _StubApiClient(SharedPreferences prefs)
      : super(
          baseUrl: 'https://stub.invalid',
          dio: Dio(),
          session: SessionStore(prefs),
        );

  @override
  Future<Result<Map<String, dynamic>>> getJson(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    if (path.endsWith('/auth/me')) {
      return Result.success(const {'authenticated': true});
    }
    if (path.endsWith('/galleries')) {
      // 一个能渲染出来的画廊就够：点它才会走真实的导航调用点。
      return Result.success(const {
        'items': [
          {'gid': 1000001, 'title': '测试画廊', 'on_disk': true, 'pages_found': 3},
        ],
        'total': 1,
      });
    }
    return Result.error(RemoteException(message: '测试未预期的 GET：$path'));
  }

  /// 事件流直接结束：真实的 `streamEvents` 自带重连退避（定时器），在假时钟里会让
  /// `pumpAndSettle` 一直有帧可等。
  @override
  Stream<SseEvent> streamEvents({CancelToken? cancelToken}) =>
      const Stream<SseEvent>.empty();
}
