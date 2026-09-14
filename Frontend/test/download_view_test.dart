import 'package:ehviewer_online/common/config/app_theme.dart';
import 'package:ehviewer_online/core/exception/global_exception.dart';
import 'package:ehviewer_online/core/util/result_util.dart';
import 'package:ehviewer_online/feature/download/datasource/runtime/download_task_runtime.dart';
import 'package:ehviewer_online/feature/download/enum/download_phase.dart';
import 'package:ehviewer_online/feature/download/enum/download_status.dart';
import 'package:ehviewer_online/feature/download/model/entity/download_manifest.dart';
import 'package:ehviewer_online/feature/download/model/entity/download_page_entry.dart';
import 'package:ehviewer_online/feature/download/model/state/download_task_state.dart';
import 'package:ehviewer_online/feature/download/model/vo/downloaded_gallery_vo.dart';
import 'package:ehviewer_online/feature/download/service/download_service.dart';
import 'package:ehviewer_online/feature/download/ui/provider/download_detail_provider.dart';
import 'package:ehviewer_online/feature/download/ui/view/download_view.dart';
import 'package:ehviewer_online/feature/download/ui/view/gallery_download_view.dart';
import 'package:ehviewer_online/feature/library/enum/availability.dart';
import 'package:ehviewer_online/feature/library/enum/meta_source.dart';
import 'package:ehviewer_online/feature/library/enum/title_source.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_detail_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/page_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/spider_info_vo.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

/// 下载管理页的渲染与删除流程。
///
/// 用假 service 覆盖「本机有什么」和「删了没有」：这里要钉住的是界面决策——空态、
/// 平台不支持、删除必须先确认——而不是文件系统本身（那在 `download_service_test`
/// 里测）。
void main() {
  testWidgets('平台没有文件系统时明说，而不是显示一个空列表', (tester) async {
    final service = _FakeDownloadService(supported: false, items: []);

    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    expect(find.text('此平台不支持本地下载'), findsOneWidget);
    expect(find.text('还没有下载任何画廊'), findsNothing);
  });

  testWidgets('没有下载时给出下一步该做什么', (tester) async {
    final service = _FakeDownloadService(supported: true, items: []);

    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    expect(find.text('还没有下载任何画廊'), findsOneWidget);
    expect(find.textContaining('画廊详情页'), findsOneWidget);
  });

  testWidgets('删除先二次确认，确认后调 service 并给反馈', (tester) async {
    final service = _FakeDownloadService(supported: true, items: [_item(7)]);

    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    expect(find.text('测试画廊'), findsOneWidget);
    expect(find.textContaining('1 页'), findsOneWidget);
    // 卡片点进去是阅读器（离线也能读），不是需要服务器的详情页。
    expect(find.text('点一下从本机阅读'), findsOneWidget);

    await tester.tap(find.widgetWithText(FButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除本地下载'), findsOneWidget, reason: '危险操作必须先确认');

    await tester.tap(find.widgetWithText(FButton, '删除本机文件'));
    await tester.pumpAndSettle();

    expect(service.deleted, [7]);
    expect(find.text('已删除'), findsOneWidget);
    expect(find.text('测试画廊'), findsNothing, reason: '删完列表要刷新');
  });

  testWidgets('取消确认时什么都不做', (tester) async {
    final service = _FakeDownloadService(supported: true, items: [_item(7)]);

    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FButton, '取消'));
    await tester.pumpAndSettle();

    expect(service.deleted, isEmpty);
    expect(find.text('测试画廊'), findsOneWidget);
  });

  testWidgets('删除失败时如实报错，并保留列表里的那一项', (tester) async {
    final service = _FakeDownloadService(
      supported: true,
      items: [_item(7)],
      deleteError: const LocalStorageException(message: '磁盘被占用了'),
    );

    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FButton, '删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FButton, '删除本机文件'));
    await tester.pumpAndSettle();

    expect(find.text('删除失败'), findsOneWidget);
    expect(find.text('磁盘被占用了'), findsOneWidget);
    expect(find.text('测试画廊'), findsOneWidget, reason: '删除失败时列表不能凭空少一项');
  });

  group('单本下载页', _galleryPageTests);
}

/// 单本下载页的三种状态。
///
/// 这一页的决策全在文案与按钮上：「下载 / 继续下载 / 取消」说错了会让用户重复下一次
/// 已经下过的 700 页，所以值得钉住。
void _galleryPageTests() {
  testWidgets('没下载过：给出下载按钮与预计大小', (tester) async {
    final service = _FakeDownloadService(supported: true, items: []);

    await tester.pumpWidget(_wrapPage(service, _detail(pages: 3)));
    await tester.pumpAndSettle();

    expect(find.text('3 页'), findsOneWidget);
    expect(find.textContaining('3.0 KB'), findsOneWidget);
    expect(find.text('无'), findsOneWidget, reason: '本机副本那一行该说「无」');
    expect(find.widgetWithText(FButton, '下载到本机'), findsOneWidget);
    expect(find.widgetWithText(FButton, '删除本地下载'), findsNothing);
  });

  testWidgets('下到一半：按钮变成继续下载，并给出删除入口', (tester) async {
    final service = _FakeDownloadService(
      supported: true,
      items: [_item(7, status: DownloadStatus.partial)],
    );

    await tester.pumpWidget(_wrapPage(service, _detail(pages: 3)));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FButton, '继续下载'), findsOneWidget);
    expect(find.textContaining(DownloadStatus.partial.label), findsOneWidget);
    expect(find.widgetWithText(FButton, '删除本地下载'), findsOneWidget);
  });

  testWidgets('下载中：显示进度与取消，不让重复触发下载', (tester) async {
    final service = _FakeDownloadService(supported: true, items: []);

    await tester.pumpWidget(
      _wrapPage(
        service,
        _detail(pages: 3),
        task: const DownloadTaskState(
          gid: 7,
          phase: DownloadPhase.downloading,
          done: 1,
          total: 3,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('下载中 1/3'), findsOneWidget);
    expect(find.widgetWithText(FButton, '取消下载'), findsOneWidget);
    expect(find.widgetWithText(FButton, '下载到本机'), findsNothing);
  });

  testWidgets('平台不支持时明说，而不是给一个点了没用的按钮', (tester) async {
    final service = _FakeDownloadService(supported: false, items: []);

    await tester.pumpWidget(_wrapPage(service, _detail(pages: 3)));
    await tester.pumpAndSettle();

    expect(find.text('此平台不支持本地下载'), findsOneWidget);
    expect(find.widgetWithText(FButton, '下载到本机'), findsNothing);
  });
}

/// 造一条下载记录。
DownloadedGalleryVo _item(int gid, {DownloadStatus status = DownloadStatus.complete}) =>
    DownloadedGalleryVo(
      manifest: DownloadManifest(
        gid: gid,
        title: '测试画廊',
        // 空封面：widget 测试不碰网络与图片解码。
        coverPath: '',
        status: status,
        downloadedAtMs: DateTime(2026, 1, 2).millisecondsSinceEpoch,
        pages: const [DownloadPageEntry(filename: '001.jpg', mtimeMs: 1)],
      ),
      bytes: 2048,
    );

/// 造一份画廊详情。
GalleryDetailVo _detail({required int pages}) => GalleryDetailVo(
      gallery: GalleryVo(
        gid: 7,
        token: 'tok',
        title: '测试画廊',
        titleJpn: '',
        titleSource: TitleSource.db,
        dirName: '7-测试画廊',
        artists: const [],
        groups: const [],
        series: const [],
        events: const [],
        editions: const [],
        category: 1,
        posted: '',
        uploader: '',
        rating: 0,
        simpleLanguage: '',
        label: '',
        state: 3,
        downloadTimeMs: 0,
        pagesExpected: pages,
        pagesFound: pages,
        totalBytes: 0,
        coverUrl: '',
        coverKind: 'none',
        availability: Availability.ok,
        anomalies: const [],
        metaSource: MetaSource.db,
        onDisk: true,
      ),
      pagesDetail: [
        for (var i = 0; i < pages; i++)
          PageVo(
            index: i,
            filename: '0000000${i + 1}.jpg',
            ext: '.jpg',
            // 三页各 1 KB，正好能断言「预计大小 3.0 KB」。
            size: 1024,
            mtimeMs: 1,
            url: '/img/7/$i',
          ),
      ],
      spiderInfo: SpiderInfoVo.empty,
    );

/// 单本下载页的装配：详情直接给值（不经过 library service），任务状态按需替换。
Widget _wrapPage(
  DownloadService service,
  GalleryDetailVo detail, {
  DownloadTaskState? task,
}) {
  return ProviderScope(
    overrides: [
      downloadServiceProvider.overrideWithValue(service),
      downloadDetailProvider(detail.gallery.gid).overrideWith((ref) async => detail),
      if (task != null) downloadTaskProvider.overrideWith(() => _FixedTaskRuntime(task)),
    ],
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true),
      builder: (context, navigator) => FTheme(
        data: buildBrandThemes(touch: true).$1,
        child: FToaster(child: navigator ?? const SizedBox.shrink()),
      ),
      home: GalleryDownloadView(gid: detail.gallery.gid),
    ),
  );
}

/// 固定返回某个任务状态的 runtime，用来测「下载中」的界面。
class _FixedTaskRuntime extends DownloadTaskRuntime {
  _FixedTaskRuntime(this._state);

  final DownloadTaskState _state;

  @override
  DownloadTaskState build() => _state;
}

Widget _wrap(DownloadService service) {
  return ProviderScope(
    overrides: [downloadServiceProvider.overrideWithValue(service)],
    child: MaterialApp(
      theme: ThemeData(useMaterial3: true),
      builder: (context, navigator) => FTheme(
        data: buildBrandThemes(touch: true).$1,
        child: FToaster(child: navigator ?? const SizedBox.shrink()),
      ),
      home: const DownloadView(),
    ),
  );
}

/// 只实现管理页用得到的那些方法的假 service。
///
/// 用 `implements` 而不是继承：要替换的是**能力**，不是某个实现细节；页面之外的方法
/// 走到就抛，正好说明测试没覆盖到。
class _FakeDownloadService implements DownloadService {
  _FakeDownloadService({
    required this.supported,
    required this.items,
    this.deleteError,
  });

  @override
  final bool supported;

  final List<DownloadedGalleryVo> items;
  final GlobalException? deleteError;

  final List<int> deleted = [];

  @override
  Future<Result<List<DownloadedGalleryVo>>> list() async =>
      Result.success(items);

  @override
  Future<Result<void>> delete(int gid) async {
    final error = deleteError;
    if (error != null) return Result.error(error);
    deleted.add(gid);
    items.removeWhere((item) => item.gid == gid);
    return const Result.success(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该被管理页调用');
}
