import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ehviewer_online/core/exception/global_exception.dart';
import 'package:ehviewer_online/core/util/result_util.dart';
import 'package:ehviewer_online/feature/download/datasource/local/download_file_local_datasource.dart';
import 'package:ehviewer_online/feature/download/datasource/remote/download_remote_datasource.dart';
import 'package:ehviewer_online/feature/download/enum/download_outcome.dart';
import 'package:ehviewer_online/feature/download/enum/download_status.dart';
import 'package:ehviewer_online/feature/download/model/dto/download_page_dto.dart';
import 'package:ehviewer_online/feature/download/model/dto/download_request_dto.dart';
import 'package:ehviewer_online/feature/download/model/entity/download_manifest.dart';
import 'package:ehviewer_online/feature/download/model/entity/download_page_entry.dart';
import 'package:ehviewer_online/feature/download/repository/download_repository.dart';
import 'package:ehviewer_online/feature/download/service/download_service.dart';
import 'package:ehviewer_online/feature/library/enum/availability.dart';
import 'package:ehviewer_online/feature/library/enum/meta_source.dart';
import 'package:ehviewer_online/feature/library/enum/title_source.dart';
import 'package:ehviewer_online/feature/library/model/vo/page_vo.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_file_store.dart';

/// 下载模块的行为测试。
///
/// 用内存里的假 [FileStore] 与假远端，所以「断点续传」「身份校验」「取消」这些真正
/// 会出错的规则都可以在毫秒级验证，不需要文件系统也不需要网络。
void main() {
  late MemoryFileStore store;
  late _FakeRemote remote;
  late DownloadService service;

  setUp(() {
    store = MemoryFileStore();
    remote = _FakeRemote();
    service = DownloadService(
      DownloadRepository(
        DownloadFileLocalDatasource(store),
        remote,
      ),
    );
  });

  group('页文件名', () {
    test('按位置补零，保留规规矩矩的扩展名', () {
      expect(_page(0, '001.jpg').position, 0);
      expect(
        DownloadFileLocalDatasource.pageFileName(_page(7, '001.JPG')),
        '0007.jpg',
      );
      expect(
        DownloadFileLocalDatasource.pageFileName(_page(1234, 'x.webp')),
        '1234.webp',
      );
    });

    test('没有扩展名或扩展名可疑时落到 .bin，而不是把怪名字写到磁盘上', () {
      expect(
        DownloadFileLocalDatasource.pageFileName(_page(1, 'page001')),
        '0001.bin',
      );
      expect(
        DownloadFileLocalDatasource.pageFileName(_page(1, 'a.b/c')),
        '0001.bin',
      );
      expect(
        DownloadFileLocalDatasource.pageFileName(_page(1, 'a.verylongext')),
        '0001.bin',
      );
    });
  });

  group('清单', () {
    test('JSON 往返保住 gid、状态、标题与每页身份', () {
      final manifest = DownloadManifest(
        gid: 42,
        title: '标题',
        coverPath: '/thumb/42?v=1',
        status: DownloadStatus.complete,
        downloadedAtMs: 1234,
        pages: const [
          DownloadPageEntry(filename: '001.jpg', mtimeMs: 10),
          DownloadPageEntry(filename: '002.jpg', mtimeMs: 20),
        ],
      );

      final restored = DownloadManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>,
      );

      expect(restored.gid, 42);
      expect(restored.title, '标题');
      expect(restored.coverPath, '/thumb/42?v=1');
      expect(restored.status, DownloadStatus.complete);
      expect(restored.downloadedAtMs, 1234);
      expect(restored.pages.length, 2);
      expect(restored.entryAt(1)!.filename, '002.jpg');
      expect(restored.entryAt(1)!.mtimeMs, 20);
      expect(restored.entryAt(9), isNull);
    });

    test('看不懂的状态当成未完成：宁可让用户再下一次，也不能让阅读器去读不存在的页', () {
      expect(DownloadStatus.parse('wat'), DownloadStatus.partial);
      expect(DownloadStatus.parse(null), DownloadStatus.partial);
    });
  });

  group('页身份校验', () {
    test('文件名与修改时间都一致才算同一张图', () {
      const local = DownloadPageEntry(filename: '001.jpg', mtimeMs: 10);
      expect(local.matches(const DownloadPageEntry(filename: '001.jpg', mtimeMs: 10)), isTrue);
      expect(local.matches(const DownloadPageEntry(filename: '002.jpg', mtimeMs: 10)), isFalse);
      expect(local.matches(const DownloadPageEntry(filename: '001.jpg', mtimeMs: 11)), isFalse);
    });

    test('服务端没报修改时间时退化为只比文件名', () {
      const local = DownloadPageEntry(filename: '001.jpg', mtimeMs: 0);
      expect(local.matches(const DownloadPageEntry(filename: '001.jpg', mtimeMs: 99)), isTrue);
      expect(local.matches(const DownloadPageEntry(filename: '002.jpg', mtimeMs: 0)), isFalse);
    });
  });

  group('下载', () {
    test('下完所有页，写出完整清单与文件', () async {
      final progress = <String>[];
      final result = await service.download(
        _request(gid: 7, pages: [_page(0, '001.jpg'), _page(1, '002.jpg')]),
        onProgress: (done, total) => progress.add('$done/$total'),
      );

      expect(result.isSuccess, isTrue);
      expect(result.data, DownloadOutcome.completed);
      expect(progress, ['0/2', '1/2', '2/2']);
      expect(remote.fetched, ['/img/7/0', '/img/7/1']);

      final listed = await service.list();
      expect(listed.data!.length, 1);
      final item = listed.data!.single;
      expect(item.gid, 7);
      expect(item.displayTitle, '画廊标题');
      expect(item.pageCount, 2);
      expect(item.isComplete, isTrue);
      expect(item.bytes, greaterThan(0));
      expect(item.coverPath, '/thumb/7?v=3');
    });

    test('中断后再下会跳过已存在的页（断点续传）', () async {
      // 上一次下到一半：清单是 partial，两页文件在磁盘上。
      final request = _request(
        gid: 7,
        pages: [_page(0, '001.jpg'), _page(1, '002.jpg'), _page(2, '003.jpg')],
      );
      // 前两页取完，第三页取的时候就「点了取消」。
      remote.successBeforeCancel = 2;
      final cancelled = await service.download(request);
      expect(cancelled.data, DownloadOutcome.cancelled);
      expect(remote.fetched, ['/img/7/0', '/img/7/1', '/img/7/2']);

      remote.successBeforeCancel = null;
      final resumed = await service.download(request);
      expect(resumed.data, DownloadOutcome.completed);
      expect(
        remote.fetched,
        ['/img/7/0', '/img/7/1', '/img/7/2', '/img/7/2'],
        reason: '只有没下完的第 2 页该重下，前两页已经在磁盘上',
      );

      final item = (await service.list()).data!.single;
      expect(item.isComplete, isTrue);
      expect(item.pageCount, 3);
    });

    test('取消：保留已下的页，清单保持未完成', () async {
      final request = _request(
        gid: 7,
        pages: [_page(0, '001.jpg'), _page(1, '002.jpg')],
      );
      remote.successBeforeCancel = 1;
      final result = await service.download(request, cancelToken: CancelToken());

      expect(result.isSuccess, isTrue);
      expect(result.data, DownloadOutcome.cancelled);
      expect(store.files.keys.any((path) => path.endsWith('0000.jpg')), isTrue);

      final item = (await service.list()).data!.single;
      expect(item.isComplete, isFalse);
      expect(item.statusLabel, DownloadStatus.partial.label);
    });

    test('取消令牌已取消时不开始取图，也不留下「未完成」记录', () async {
      final token = CancelToken()..cancel();
      final result = await service.download(
        _request(gid: 7, pages: [_page(0, '001.jpg')]),
        cancelToken: token,
      );

      expect(result.data, DownloadOutcome.cancelled);
      expect(remote.fetched, isEmpty);
      expect((await service.list()).data, isEmpty, reason: '一次都没下，就不该有记录');
    });

    test('回源失败时报出原因并保留现场', () async {
      remote.failOn = '/img/7/1';
      final result = await service.download(
        _request(gid: 7, pages: [_page(0, '001.jpg'), _page(1, '002.jpg')]),
      );

      expect(result.isError, isTrue);
      expect(result.error!.message, contains('炸了'));
      // 第一页留着，第二次点「继续下载」可以少下一页。
      expect(store.files.keys.any((path) => path.endsWith('0000.jpg')), isTrue);
      expect((await service.list()).data!.single.isComplete, isFalse);
    });

    test('没有页时不写清单，直接报错', () async {
      final result = await service.download(_request(gid: 7, pages: const []));

      expect(result.isError, isTrue);
      expect(result.error, isA<BusinessException>());
      expect((await service.list()).data, isEmpty);
    });

    test('服务端缩水后收尾会删掉多余的旧页文件，否则占用里混着不存在的页', () async {
      await service.download(
        _request(
          gid: 7,
          pages: [_page(0, '001.jpg'), _page(1, '002.jpg'), _page(2, '003.jpg')],
        ),
      );
      // 服务端重扫后只剩两页。
      await service.download(
        _request(gid: 7, pages: [_page(0, '001.jpg'), _page(1, '002.jpg')]),
      );

      final names = store.files.keys.map((p) => p.split('/').last).toSet();
      expect(names.contains('0002.jpg'), isFalse, reason: '第三页已经不存在了');
      expect(names.contains('0000.jpg'), isTrue);
      expect(names.contains('manifest.json'), isTrue);
    });
  });

  group('本地优先读页', () {
    test('本地有且身份一致时不回源', () async {
      final page = _page(0, '001.jpg');
      await service.download(_request(gid: 7, pages: [page]));
      remote.fetched.clear();

      final bytes = await service.pageBytes(7, page);

      expect(bytes.isSuccess, isTrue);
      expect(utf8.decode(bytes.data!), 'img:/img/7/0');
      expect(remote.fetched, isEmpty, reason: '本地命中就不该再走网络');
    });

    test('本地副本与当前详情不是同一张图时回源，而不是显示错的一页', () async {
      await service.download(_request(gid: 7, pages: [_page(0, '001.jpg')]));
      remote.fetched.clear();

      // 同一位置换成了另一张图（服务端重扫过）。
      final changed = _page(0, '009.jpg');
      final bytes = await service.pageBytes(7, changed);

      expect(bytes.isSuccess, isTrue);
      expect(remote.fetched, ['/img/7/0']);
      // 回源拿到的是新内容，而不是磁盘上那份过期的旧图。
      expect(utf8.decode(bytes.data!), 'img:/img/7/0');
    });

    test('没下载过时直接回源', () async {
      final bytes = await service.pageBytes(7, _page(0, '001.jpg'));
      expect(bytes.isSuccess, isTrue);
      expect(remote.fetched, ['/img/7/0']);
    });

    test('回源失败时返回失败而不是空字节', () async {
      remote.failOn = '/img/7/0';
      final bytes = await service.pageBytes(7, _page(0, '001.jpg'));
      expect(bytes.isError, isTrue);
    });
  });

  group('离线重建详情（断网阅读）', () {
    test('标题与页来自清单，其余元数据落到 unknown 而不是编一个值', () async {
      await service.download(
        _request(gid: 7, pages: [_page(0, '001.jpg'), _page(1, '002.jpg')]),
      );

      final result = await service.localDetail(7);

      expect(result.isSuccess, isTrue);
      final detail = result.data!;
      expect(detail.gallery.gid, 7);
      expect(detail.gallery.title, '画廊标题');
      expect(detail.gallery.coverUrl, '/thumb/7?v=3');
      expect(detail.gallery.onDisk, isTrue);
      expect(detail.gallery.pagesExpected, 2);
      expect(detail.gallery.pagesFound, 2);
      // 本地没有的东西一律 unknown：编一个像模像样的值会被下一个人当成事实。
      expect(detail.gallery.titleSource, TitleSource.unknown);
      expect(detail.gallery.metaSource, MetaSource.unknown);
      expect(detail.gallery.availability, Availability.unknown);
      expect(detail.pagesDetail.length, 2);
      expect(detail.pagesDetail.first.filename, '001.jpg');
      expect(detail.pagesDetail.first.index, 0);
      expect(detail.pagesDetail.first.ext, '.jpg');
      // 离线没有可回源的地址，但本机有这一页时仍然能读到。
      expect(detail.pagesDetail.first.url, isEmpty);
      expect(detail.pagesDetail.first.mtimeMs, 100);
    });

    test('没下载过时返回 null，而不是一份空详情的「离线可读」', () async {
      final result = await service.localDetail(7);
      expect(result.isSuccess, isTrue);
      expect(result.data, isNull);
    });

    test('离线重建出的页能直接按位置读到本机字节', () async {
      await service.download(
        _request(gid: 7, pages: [_page(0, '001.jpg'), _page(1, '002.jpg')]),
      );
      final detail = (await service.localDetail(7)).data!;
      remote.fetched.clear();

      final bytes = await service.pageBytes(7, _dtoOf(detail.pagesDetail[1], 1));

      // 回源的地址是空的，所以这一步能成功本身就是「读了本机」的证据。
      expect(bytes.isSuccess, isTrue);
      expect(utf8.decode(bytes.data!), 'img:/img/7/1');
      expect(remote.fetched, isEmpty);
    });

    test('本机缺页时如实报「没有可用的图片地址」，而不是假装读了', () async {
      // 下到一半：清单在，第二页没下下来。
      remote.successBeforeCancel = 1;
      await service.download(
        _request(gid: 7, pages: [_page(0, '001.jpg'), _page(1, '002.jpg')]),
      );
      remote.successBeforeCancel = null;
      final detail = (await service.localDetail(7)).data!;

      final bytes = await service.pageBytes(7, _dtoOf(detail.pagesDetail[1], 1));

      expect(bytes.isError, isTrue);
      expect(bytes.error!.message, contains('图片地址'));
    });
  });

  group('删除', () {
    test('删一本之后列表里没有它，文件也没了', () async {
      await service.download(
        _request(gid: 7, pages: [_page(0, '001.jpg')]),
      );
      expect((await service.list()).data, hasLength(1));

      final deleted = await service.delete(7);

      expect(deleted.isSuccess, isTrue);
      expect((await service.list()).data, isEmpty);
      expect(store.files, isEmpty);
    });

    test('全部删除清空根目录', () async {
      await service.download(_request(gid: 7, pages: [_page(0, '001.jpg')]));
      await service.download(_request(gid: 8, pages: [_page(0, '001.jpg')]));

      final deleted = await service.deleteAll();

      expect(deleted.isSuccess, isTrue);
      expect((await service.list()).data, isEmpty);
      expect(await service.totalBytes().then((r) => r.data), 0);
    });
  });

  group('平台没有文件系统（Web）', () {
    setUp(() {
      store = MemoryFileStore(supported: false);
      service = DownloadService(
        DownloadRepository(
          DownloadFileLocalDatasource(store),
          remote,
        ),
      );
    });

    test('明确说「不支持」，而不是假装下载成功', () async {
      final result = await service.download(
        _request(gid: 7, pages: [_page(0, '001.jpg')]),
      );

      expect(result.isError, isTrue);
      expect(result.error, isA<BusinessException>());
      expect(service.supported, isFalse);
    });

    test('读页退化为每次都回源', () async {
      final bytes = await service.pageBytes(7, _page(0, '001.jpg'));
      expect(bytes.isSuccess, isTrue);
      expect(remote.fetched, ['/img/7/0']);
    });
  });
}

/// 按阅读器的做法把一页详情摊成取页入参（阅读器就是这么调 download 的）。
DownloadPageDto _dtoOf(PageVo page, int position) => DownloadPageDto(
      position: position,
      filename: page.filename,
      mtimeMs: page.mtimeMs,
      url: page.url,
    );

/// 造一页。
DownloadPageDto _page(int position, String filename) => DownloadPageDto(
      position: position,
      filename: filename,
      mtimeMs: 100 + position,
      url: '/img/7/$position',
    );

/// 造一次下载请求。
DownloadRequestDto _request({
  required int gid,
  required List<DownloadPageDto> pages,
}) =>
    DownloadRequestDto(
      gid: gid,
      title: '画廊标题',
      coverPath: '/thumb/$gid?v=3',
      pages: [
        for (final page in pages)
          DownloadPageDto(
            position: page.position,
            filename: page.filename,
            mtimeMs: page.mtimeMs,
            url: '/img/$gid/${page.position}',
          ),
      ],
    );

/// 假远端：返回可判定的内容，并记录取过哪些路径。
class _FakeRemote implements DownloadRemoteDatasource {
  final List<String> fetched = [];

  /// 这个路径一律失败，用来验证错误路径。
  String? failOn;

  /// 前几张图正常返回，之后按「用户点了取消」的方式抛取消异常——这就是真实
  /// `ApiClient` 的行为：取消是唯一会抛出而不是返回 Result 的情况。
  int? successBeforeCancel;

  @override
  Future<Result<Uint8List>> fetchPageBytes(
    String path, {
    CancelToken? cancelToken,
  }) async {
    fetched.add(path);
    // 与真实 `DownloadRemoteDatasource` 同一条契约：空地址是错误，不是「取到空内容」。
    // 假实现漏掉这一条，就会把「本机缺页且离线」测成成功。
    if (path.isEmpty) {
      return Result.error(const ParsingException(message: '该页没有可用的图片地址'));
    }
    if (path == failOn) {
      return Result.error(RemoteException(message: '炸了：$path'));
    }
    final budget = successBeforeCancel;
    if (budget != null && fetched.length > budget) {
      cancelToken?.cancel();
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.cancel,
      );
    }
    return Result.success(Uint8List.fromList(utf8.encode('img:$path')));
  }
}
