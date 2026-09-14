import 'package:ehviewer_online/common/config/app_theme.dart';
import 'package:ehviewer_online/common/config/app_config.dart';
import 'package:ehviewer_online/core/service/preferences_provider.dart';
import 'package:ehviewer_online/feature/library/enum/availability.dart';
import 'package:ehviewer_online/feature/library/enum/meta_source.dart';
import 'package:ehviewer_online/feature/library/enum/title_source.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_detail_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/page_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/spider_info_vo.dart';
import 'package:ehviewer_online/feature/library/ui/provider/gallery_detail_provider.dart';
import 'package:ehviewer_online/feature/library/ui/view/gallery_detail_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 画廊详情页的窄屏布局。
///
/// 这条测试来自一张真机截图：320 宽的手机上，整块信息仍塞在封面右边，那一列只剩
/// 118 px——标题两三个字一换行，「元数据来源」这类键值对每行一个字，胶囊标签直接
/// RenderFlex 溢出（黄色条纹）。平板与桌面（≥720）本来就没问题，所以这里主要钉住
/// **窄屏**：不溢出、事实整宽、两个入口按钮都在。
void main() {
  const title = '《狼人刑警的催眠治疗》';

  Future<void> pumpDetail(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          galleryDetailProvider(_gid).overrideWith((ref) async => _detail()),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          builder: (context, navigator) => FTheme(
            data: buildBrandThemes(touch: true).$1,
            child: FToaster(child: navigator ?? const SizedBox.shrink()),
          ),
          home: const GalleryDetailView(gid: _gid),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final width in [320.0, 360.0, 390.0]) {
    testWidgets('$width 宽的手机上不溢出，标题与事实都拿得到整行宽度', (tester) async {
      await pumpDetail(tester, Size(width, 640));

      // 布局溢出（RenderFlex overflow）也算异常：修之前这里能收到两条。
      expect(tester.takeException(), isNull);

      // FScaffold 的标题栏也渲染同一个标题，所以有两个匹配；后一个是正文里的。
      final titles = find.text(title);
      expect(titles, findsNWidgets(2));
      final body = tester.getSize(titles.at(1));
      expect(
        body.width,
        greaterThan(140),
        reason: '正文标题列至少要有 140 px，否则一行放不下几个字',
      );
      expect(
        body.height,
        lessThan(140),
        reason: '标题不该撑成三行以上（30 px 字号那版会到 200+ px）',
      );

      // 事实整宽排在封面下方，左边缘**正好**是页面自己的留白。
      //
      // 这里用精确值而不是「小于某个数」：forui 的 FScaffold 默认会再给内容左右各
      // 12 px（`pagePadding` 的横向部分），叠在页面留白外面就是两边各一条多余的边
      // ——这条断言会立刻抓到它回来（36 而不是 24）。
      expect(tester.getRect(find.text('元数据来源')).left, AppSpacing.xl);

      // 两个入口都在：窄屏上「下载」不能被挤掉。
      expect(find.widgetWithText(FButton, '开始阅读'), findsOneWidget);
      expect(find.widgetWithText(FButton, '下载'), findsOneWidget);
    });
  }

  testWidgets('平板 / 桌面（≥720）仍是海报式并排', (tester) async {
    await pumpDetail(tester, const Size(900, 800));

    expect(tester.takeException(), isNull);

    // 标题与事实都在右栏：左边缘 = 页面留白 + 封面宽 + 间距 = 24 + 260 + 24。
    expect(tester.getRect(find.text('元数据来源')).left, AppSpacing.xl * 2 + 260);
    expect(find.widgetWithText(FButton, '下载'), findsOneWidget);
  });
}

const int _gid = 1000001;

GalleryDetailVo _detail() => GalleryDetailVo(
      gallery: GalleryVo(
        gid: _gid,
        token: 'tok',
        title: '《狼人刑警的催眠治疗》',
        titleJpn: '',
        titleSource: TitleSource.dirname,
        dirName: '1000001-狼人刑警的催眠治疗',
        artists: const ['Tighnari_55'],
        groups: const [],
        series: const [],
        events: const [],
        editions: const [],
        category: 0,
        posted: '',
        uploader: '',
        rating: 0,
        simpleLanguage: '',
        label: '',
        state: 3,
        downloadTimeMs: 0,
        pagesExpected: 14,
        pagesFound: 14,
        totalBytes: 1992294,
        // 空封面：这条测试只关心排版，不碰网络与图片解码。
        coverUrl: '',
        coverKind: 'none',
        availability: Availability.ok,
        anomalies: const [],
        metaSource: MetaSource.localOnly,
        onDisk: true,
      ),
      // 页网格另有测试；这里留空，免得 14 张缩略图把布局测量搅乱。
      pagesDetail: const <PageVo>[],
      spiderInfo: SpiderInfoVo.empty,
    );
