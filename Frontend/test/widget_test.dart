import 'package:dio/dio.dart';
import 'package:ehviewer_online/common/config/app_theme.dart';
import 'package:ehviewer_online/core/exception/global_exception.dart';
import 'package:ehviewer_online/core/service/api_client.dart';
import 'package:ehviewer_online/core/service/dio_provider.dart';
import 'package:ehviewer_online/core/service/file_store.dart';
import 'package:ehviewer_online/core/service/preferences_provider.dart';
import 'package:ehviewer_online/core/service/session_store.dart';
import 'package:ehviewer_online/core/util/format_util.dart';
import 'package:ehviewer_online/core/util/result_util.dart';
import 'package:ehviewer_online/feature/auth/ui/view/login_view.dart';
import 'package:ehviewer_online/feature/library/enum/availability.dart';
import 'package:ehviewer_online/feature/library/enum/gallery_anomaly.dart';
import 'package:ehviewer_online/feature/library/enum/meta_source.dart';
import 'package:ehviewer_online/feature/library/enum/tag_dimension.dart';
import 'package:ehviewer_online/feature/library/enum/title_source.dart';
import 'package:ehviewer_online/feature/library/model/vo/facet_value_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/facets_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_detail_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/page_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/spider_info_vo.dart';
import 'package:ehviewer_online/feature/library/ui/provider/facets_provider.dart';
import 'package:ehviewer_online/feature/library/ui/widget/filter_sheet.dart';
import 'package:ehviewer_online/feature/library/ui/widget/gallery_card.dart';
import 'package:ehviewer_online/feature/reader/ui/provider/reader_provider.dart';
import 'package:ehviewer_online/feature/reader/ui/view/reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_file_store.dart';

/// 编码了「决定」的那些部分的 widget 测试，外加格式化函数。
///
/// 用桩客户端而不是真网络：`TestWidgetsFlutterBinding` 会把 HTTP 客户端换成对
/// 所有请求回 400 的假实现，所以期待真实响应的 widget 测试根本跑不起来。真实
/// 传输、cookie 与 JSON 解析在 `api_client_test.dart` 里对着真实 socket 测；这里
/// 测渲染与交互决策。
void main() {
  group('formatters', () {
    test('formatBytes 在 B 级不带小数、KB 以上带一位', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
    });

    test('formatDateTime 对「没有快照」的情况给出占位而不是 1970', () {
      expect(formatDateTime(0), '—');
    });

    test('formatRelative 描述陈旧程度', () {
      final now = DateTime(2026, 1, 1, 12).millisecondsSinceEpoch;
      expect(formatRelative(now, nowMs: now), '0 秒前');
      expect(formatRelative(now - 5 * 60 * 1000, nowMs: now), '5 分钟前');
      expect(formatRelative(now - 3 * 3600 * 1000, nowMs: now), '3 小时前');
      // 时钟偏移不该报警，只说「刚刚」。
      expect(formatRelative(now + 60 * 1000, nowMs: now), '刚刚');
      expect(formatRelative(0, nowMs: now), '未知');
    });

    test('languageLabel 映射已知代码、原样透传未知代码', () {
      expect(languageLabel('ZH'), '中文');
      expect(languageLabel('en'), '英语');
      expect(languageLabel('XX'), 'XX');
    });

    test('categoryLabel 承认自己是推测', () {
      expect(categoryLabel(1), '同人志');
      expect(categoryLabel(999), '未分类');
    });
  });

  group('GalleryVo', () {
    test('displayTitle 依次回退且永不为空', () {
      expect(_gallery(title: 'A').displayTitle, 'A');
      expect(_gallery(title: '', titleJpn: 'B').displayTitle, 'B');
      expect(_gallery(title: '', titleJpn: '', gid: 7).displayTitle, '#7');
    });

    test('missingPageCount 在元数据没声明页数时为 null', () {
      expect(_gallery(pagesExpected: 0, pagesFound: 0).missingPageCount, isNull);
      expect(_gallery(pagesExpected: 5, pagesFound: 5).missingPageCount, isNull);
      expect(_gallery(pagesExpected: 5, pagesFound: 3).missingPageCount, 2);
    });

    test('isReadable 要求目录存在且有页', () {
      expect(_gallery(onDisk: true, pagesFound: 3).isReadable, isTrue);
      expect(_gallery(onDisk: false, pagesFound: 3).isReadable, isFalse);
      expect(_gallery(onDisk: true, pagesFound: 0).isReadable, isFalse);
    });

    test('tagsOf 返回对应维度的标签', () {
      final gallery = _gallery(
        artists: const ['balmos'],
        groups: const ['黑曜石汉化组'],
      );
      expect(gallery.tagsOf(TagDimension.artist), ['balmos']);
      expect(gallery.tagsOf(TagDimension.group), ['黑曜石汉化组']);
      expect(gallery.tagsOf(TagDimension.series), isEmpty);
    });
  });

  group('LoginView', () {
    testWidgets('空令牌在本地被拒，不发请求', (tester) async {
      final prefs = await _preferences();
      await tester.pumpWidget(_wrap(
        prefs,
        const LoginView(),
        client: _StubApiClient(prefs, authenticated: false),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();

      expect(find.text('令牌不能为空'), findsOneWidget);
    });

    testWidgets('未登录时也能改服务器地址——这是唯一的出口', (tester) async {
      // 路由在未认证时把设置页挡在外面，所以登录页上的这个入口不是可选功能：
      // 没有它，默认地址不对就等于应用完全不可用。
      //
      // `setMockInitialValues` 会重置缓存的实例，所以只设一次、只取一次，
      // 免得拿到两个指向不同存储的 SharedPreferences。
      SharedPreferences.setMockInitialValues({'ehw_session': 'from-old-server'});
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(_wrap(
        prefs,
        const LoginView(),
        client: _StubApiClient(prefs, authenticated: false),
      ));
      await tester.pumpAndSettle();

      expect(find.text('修改'), findsOneWidget);
      await tester.tap(find.text('修改'));
      await tester.pumpAndSettle();

      // 弹窗里有输入框和保存按钮。
      expect(find.text('服务器地址'), findsOneWidget);
      // 登录页的令牌框也是 EditableText，所以必须精确指向弹窗里那个。
      await tester.enterText(
        find.descendant(
          of: find.byType(FTextFormField),
          matching: find.byType(EditableText),
        ),
        'http://192.168.1.9:8080',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(prefs.getString('pref_base_url'), 'http://192.168.1.9:8080');
      // 会话属于上一台服务器，必须一起清掉。
      expect(prefs.getString('ehw_session'), isNull);
      // 保存成功后弹窗应当关闭。
      expect(find.text('服务器地址'), findsNothing);
    });
  });

  group('ReaderView', () {
    testWidgets('控制条用通用按钮渲染，且翻页不触发构建期失效', (tester) async {
      // 这条测试来自两次真实崩溃：
      // 1. 控制条最初把 FHeaderAction 放进了普通 Row，而它断言必须住在 FHeader
      //    里，于是先抛断言、再撑出 19 万像素的横向溢出；
      // 2. 预热回收最初在 `ReaderPreload.didUpdateWidget` 里 `ref.invalidate`，
      //    而那个回调发生在构建阶段，翻页时抛
      //    `setState() or markNeedsBuild() called during build`。
      //
      // 两条都只在**翻页**（预热窗口变化）时才现形，所以测试必须真的翻几页。
      // reader 此前一个测试都没有，这正是它们漏出去的原因。
      final prefs = await _preferences();
      const gid = 1000001;
      final detail = GalleryDetailVo(
        gallery: _gallery(gid: gid, pagesFound: 5, pagesExpected: 5),
        pagesDetail: [
          for (var i = 0; i < 5; i++)
            PageVo(
              index: i,
              filename: '0000000${i + 1}.jpg',
              ext: '.jpg',
              size: 1024,
              mtimeMs: 1,
              url: '/img/1000001/$i',
            ),
        ],
        spiderInfo: SpiderInfoVo.empty,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            apiClientProvider.overrideWithValue(
              _StubApiClient(prefs, authenticated: true),
            ),
            // 阅读器现在会先问下载模块「本机有没有这一页」，而那个模块要碰
            // `path_provider`。真实平台通道在 `testWidgets` 的假时钟里永远不会返回，
            // 换成内存实现之后这条测试仍然只关心 UI 决策。
            fileStoreProvider.overrideWithValue(MemoryFileStore()),
            readerDetailProvider(gid).overrideWith((ref) async => detail),
          ],
          child: _withForui(const ReaderView(gid: gid)),
        ),
      );
      await tester.pumpAndSettle();

      // 控制条上的翻页是两个普通按钮；用 FHeaderAction 会在这里直接失败。
      expect(find.byIcon(FLucideIcons.chevronLeft), findsOneWidget);
      expect(find.byIcon(FLucideIcons.chevronRight), findsOneWidget);

      // 连翻三页：第 0 页会滑出预热窗口（半径 2），回收路径因此被走到。
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byIcon(FLucideIcons.chevronRight));
        await tester.pumpAndSettle();
      }

      // 页码前进到第 4 页；有异常逃逸的话上面就已经失败了。
      expect(find.text('4 / 5'), findsOneWidget);
    });
  });

  group('GalleryCard', () {
    testWidgets('未同步的画廊带明确角标', (tester) async {
      final prefs = await _preferences();
      await tester.pumpWidget(_wrap(
        prefs,
        Center(
          child: SizedBox(
            width: 200,
            height: 300,
            child: GalleryCard(
              gallery: _gallery(
                availability: Availability.missing,
                onDisk: false,
                pagesFound: 0,
                pagesExpected: 0,
              ),
              onTap: () {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 目录没同步和「坏掉」看起来一模一样，除非角标说出来。
      expect(find.text('未同步'), findsOneWidget);
    });

    testWidgets('正常的画廊没有告警角标', (tester) async {
      final prefs = await _preferences();
      await tester.pumpWidget(_wrap(
        prefs,
        Center(
          child: SizedBox(
            width: 200,
            height: 300,
            child: GalleryCard(gallery: _gallery(), onTap: () {}),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('未同步'), findsNothing);
      expect(find.text('异常'), findsNothing);
    });
  });

  group('FilterSheet', () {
    testWidgets('目录名推导的维度排在最前，且用库里的真实拼写', (tester) async {
      final prefs = await _preferences();
      await tester.pumpWidget(_wrap(
        prefs,
        const FilterSheet(),
        facets: const FacetsVo(
          labels: [],
          languages: [],
          categories: [],
          availability: [],
          artists: [
            FacetValueVo(
              value: 'koukyuu denim (futee)',
              label: 'Koukyuu Denim (Futee)',
              count: 2,
            ),
          ],
          groups: [FacetValueVo(value: '黑曜石汉化组', count: 1)],
        ),
      ));
      await tester.pumpAndSettle();

      // 分区标题按维度命名。
      expect(find.text('作者/社团'), findsOneWidget);
      expect(find.text('汉化组'), findsOneWidget);
      // 快照维度为空时整块不出现——不提供永远匹配不到的条件。
      expect(find.text('可用性'), findsNothing);
    });
  });
}

// --- 测试夹具 ---------------------------------------------------------------

Future<SharedPreferences> _preferences() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

GalleryVo _gallery({
  int gid = 1000001,
  String title = 'Gallery',
  String titleJpn = '',
  bool onDisk = true,
  Availability availability = Availability.ok,
  int pagesFound = 5,
  int pagesExpected = 5,
  List<GalleryAnomaly> anomalies = const [],
  List<String> artists = const [],
  List<String> groups = const [],
  List<String> series = const [],
  List<String> events = const [],
  List<String> editions = const [],
}) {
  return GalleryVo(
    gid: gid,
    token: 'tok',
    title: title,
    titleJpn: titleJpn,
    titleSource: TitleSource.db,
    dirName: '$gid-$title',
    artists: artists,
    groups: groups,
    series: series,
    events: events,
    editions: editions,
    category: 1,
    posted: '',
    uploader: '',
    rating: 0,
    simpleLanguage: '',
    label: '',
    state: 3,
    downloadTimeMs: 0,
    pagesExpected: pagesExpected,
    pagesFound: pagesFound,
    totalBytes: 0,
    // 空封面让测试完全不碰图片。
    coverUrl: '',
    coverKind: 'none',
    availability: availability,
    anomalies: anomalies,
    metaSource: MetaSource.db,
    onDisk: onDisk,
  );
}

/// 复现 `main.dart` 搭出的 widget 环境。
///
/// 用 `material_ui` 的 `MaterialApp`（不是 `package:flutter/material.dart`）：
/// Flutter 3.44 起 Material 已从 SDK 独立成包，forui 0.26 建立在它之上，混用是
/// 类型错误。`FTheme` 放在 `builder` 里，这样 Navigator 推出来的东西（弹窗、
/// 面板）也能找到主题。
Widget _withForui(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true),
    builder: (context, navigator) => FTheme(
      // 用**应用真实的那一份**主题：测试自造一套的话，主题里的改动（比如 FScaffold
      // 的 childPadding 归零）就永远测不到。touch 固定为 true，免得结果随宿主平台变。
      data: buildBrandThemes(touch: true).$1,
      child: FToaster(child: navigator ?? const SizedBox.shrink()),
    ),
    home: child,
  );
}

Widget _wrap(
  SharedPreferences preferences,
  Widget child, {
  ApiClient? client,
  FacetsVo? facets,
}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      if (client != null) apiClientProvider.overrideWithValue(client),
      if (facets != null) facetsProvider.overrideWith((ref) async => facets),
    ],
    child: _withForui(child),
  );
}

/// 只实现测试需要的两个响应的客户端，让 widget 测试不碰 HTTP。
///
/// 它替换的是**传输层**而不是业务层：auth 的 datasource/repository/service 仍然
/// 是真的，所以「空令牌本地拦截」「会话校验」这些链路依旧被测到。
class _StubApiClient extends ApiClient {
  _StubApiClient(SharedPreferences prefs, {required this.authenticated})
      : super(
          baseUrl: 'https://stub.invalid',
          dio: Dio(),
          session: SessionStore(prefs),
        );

  final bool authenticated;

  @override
  Future<Result<Map<String, dynamic>>> getJson(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    if (path.endsWith('/auth/me')) {
      return Result.success({'authenticated': authenticated});
    }
    return Result.error(RemoteException(message: '测试未预期的 GET：$path'));
  }

  @override
  Future<Result<Map<String, dynamic>>> postJson(
    String path, {
    Object? body,
    CancelToken? cancelToken,
  }) async {
    if (path.endsWith('/auth/login')) {
      return Result.error(const UnauthorizedException());
    }
    return Result.success(const {});
  }
}
