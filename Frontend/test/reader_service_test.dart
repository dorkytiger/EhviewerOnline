import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ehviewer_online/core/exception/global_exception.dart';
import 'package:ehviewer_online/core/util/result_util.dart';
import 'package:ehviewer_online/feature/download/datasource/local/download_file_local_datasource.dart';
import 'package:ehviewer_online/feature/download/datasource/remote/download_remote_datasource.dart';
import 'package:ehviewer_online/feature/download/model/dto/download_page_dto.dart';
import 'package:ehviewer_online/feature/download/model/dto/download_request_dto.dart';
import 'package:ehviewer_online/feature/download/repository/download_repository.dart';
import 'package:ehviewer_online/feature/download/service/download_service.dart';
import 'package:ehviewer_online/feature/library/enum/availability.dart';
import 'package:ehviewer_online/feature/library/enum/meta_source.dart';
import 'package:ehviewer_online/feature/library/enum/title_source.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_detail_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/page_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/spider_info_vo.dart';
import 'package:ehviewer_online/feature/library/service/library_service.dart';
import 'package:ehviewer_online/feature/reader/service/reader_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_file_store.dart';

/// 阅读器 service 里纯逻辑的测试。
///
/// 这两个函数决定「预取哪几页」和「这一页是不是缺页」，都是页面逻辑而不是 UI
/// 逻辑——规范要求它们落在 service，也就意味着它们可以脱开 widget 树直接验证。
void main() {
  group('preloadWindow', () {
    test('以当前页为中心，半径内的页都在窗口里', () {
      expect(ReaderService.preloadWindow(5, 10, 2), [3, 4, 5, 6, 7]);
    });

    test('靠近边界时夹到范围内，而不是报错或返回空', () {
      // 第 0 页：没有负数页，窗口从 0 开始。
      expect(ReaderService.preloadWindow(0, 10, 2), [0, 1, 2]);
      // 最后一页：不越界。
      expect(ReaderService.preloadWindow(9, 10, 2), [7, 8, 9]);
    });

    test('窗口一定包含当前页', () {
      for (var current = 0; current < 10; current++) {
        expect(
          ReaderService.preloadWindow(current, 10, 2),
          contains(current),
          reason: '第 $current 页必须在自己的预热窗口里',
        );
      }
    });

    test('半径大于总数时返回全部页，不重复', () {
      expect(ReaderService.preloadWindow(1, 3, 99), [0, 1, 2]);
    });

    test('没有页或半径非法时返回空表', () {
      expect(ReaderService.preloadWindow(0, 0, 2), isEmpty);
      expect(ReaderService.preloadWindow(0, 10, -1), isEmpty);
    });
  });

  group('断网阅读', () {
    test('服务器连不上时退到本机已下载的副本继续读', () async {
      final store = MemoryFileStore();
      final download = _realDownloadService(store);
      // 先在线下载两页，再让服务器「断掉」。
      await download.download(
        DownloadRequestDto.fromGalleryDetail(_detail([0, 1])),
      );
      final reader = ReaderService(_OfflineLibraryService(), download);

      final detail = await reader.detail(1000001);

      expect(detail.isSuccess, isTrue, reason: '有本地副本就不该给用户一个网络错误页');
      expect(detail.data!.gallery.title, 'Gallery');
      expect(detail.data!.pagesDetail.length, 2);

      // 页也从本机读：详情里的 URL 是空的，能取到就说明读的是本地副本。
      final bytes = await reader.pageBytes(detail.data!, 1);
      expect(bytes.isSuccess, isTrue);
      expect(utf8.decode(bytes.data!), 'img:/img/1000001/1');
    });

    test('本机没有副本时如实报远程错误，不假装能读', () async {
      final reader = ReaderService(
        _OfflineLibraryService(),
        _realDownloadService(MemoryFileStore()),
      );

      final detail = await reader.detail(1000001);

      expect(detail.isError, isTrue);
      expect(detail.error, isA<RemoteException>());
    });
  });

  group('pageBytes', () {
    test('把页的身份整份交给下载模块，阅读器自己不拼 URL、不判断本地有没有', () async {
      final download = _RecordingDownloadService();
      final reader = ReaderService(_UnusedLibraryService(), download);

      final result = await reader.pageBytes(_detail([0, 3]), 1);

      expect(result.isSuccess, isTrue);
      expect(download.calls.length, 1);
      expect(download.gids.single, 1000001, reason: 'gid 也要一起交给下载模块');
      final call = download.calls.single;
      expect(call.position, 1);
      expect(call.filename, '00000002.jpg');
      expect(call.mtimeMs, 1);
      expect(call.url, '/img/1000001/1');
    });

    test('位置越界在本地就被拒，不惊动下载模块', () async {
      final download = _RecordingDownloadService();
      final reader = ReaderService(_UnusedLibraryService(), download);

      final result = await reader.pageBytes(_detail([0, 1]), 2);

      expect(result.isError, isTrue);
      expect(result.error, isA<ValidationException>());
      expect(download.calls, isEmpty);
    });
  });

  group('gapAt', () {
    test('文件编号与位置一致时没有可提示的东西', () {
      final detail = _detail([0, 1, 2]);
      expect(ReaderService.gapAt(detail, 1), isNull);
    });

    test('编号与位置不一致时说明差在哪', () {
      // 服务端列出的页数少于元数据声明的页数：第 1 个位置的图其实是第 3 页。
      final detail = _detail([0, 3, 4]);
      final gap = ReaderService.gapAt(detail, 1);

      expect(gap, isNotNull);
      expect(gap!.position, 1);
      expect(gap.pageIndex, 3);
    });

    test('越界位置返回 null 而不是抛异常', () {
      final detail = _detail([0, 1]);
      expect(ReaderService.gapAt(detail, -1), isNull);
      expect(ReaderService.gapAt(detail, 2), isNull);
    });
  });
}

/// 真的下载 service，只是把文件系统换成内存实现：断网阅读的链路要真的走一遍
/// 「写清单 → 重建详情 → 按位置读页」，用假的 service 就把要验的东西验掉了。
DownloadService _realDownloadService(MemoryFileStore store) => DownloadService(
      DownloadRepository(
        DownloadFileLocalDatasource(store),
        _RecordingRemote(),
      ),
    );

/// 假远端：按路径返回可判定的字节。
class _RecordingRemote implements DownloadRemoteDatasource {
  @override
  Future<Result<Uint8List>> fetchPageBytes(
    String path, {
    CancelToken? cancelToken,
  }) async {
    if (path.isEmpty) {
      return Result.error(const ParsingException(message: '该页没有可用的图片地址'));
    }
    return Result.success(Uint8List.fromList(utf8.encode('img:$path')));
  }
}

/// 服务器不可达的 library service。
class _OfflineLibraryService implements LibraryService {
  @override
  Future<Result<GalleryDetailVo>> galleryDetail(
    int gid, {
    CancelToken? cancelToken,
  }) async =>
      Result.error(const RemoteException(message: '连接超时'));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该被这个用例调用');
}

/// 记录被请求了哪一页的假下载 service。
class _RecordingDownloadService implements DownloadService {
  final List<DownloadPageDto> calls = [];
  final List<int> gids = [];

  @override
  Future<Result<Uint8List>> pageBytes(
    int gid,
    DownloadPageDto page, {
    CancelToken? cancelToken,
  }) async {
    gids.add(gid);
    calls.add(page);
    return Result.success(Uint8List.fromList(const [1, 2, 3]));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该被阅读器调用');
}

/// 阅读器的取图路径不经过 library service（详情除外），测试里用它占位。
class _UnusedLibraryService implements LibraryService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 不该被这个用例调用');
}

GalleryDetailVo _detail(List<int> pageIndices) {
  return GalleryDetailVo(
    gallery: GalleryVo(
      gid: 1000001,
      token: 'tok',
      title: 'Gallery',
      titleJpn: '',
      titleSource: TitleSource.db,
      dirName: '1000001-Gallery',
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
      pagesExpected: pageIndices.length,
      pagesFound: pageIndices.length,
      totalBytes: 0,
      coverUrl: '',
      coverKind: 'none',
      availability: Availability.ok,
      anomalies: const [],
      metaSource: MetaSource.db,
      onDisk: true,
    ),
    pagesDetail: [
      for (var position = 0; position < pageIndices.length; position++)
        PageVo(
          index: pageIndices[position],
          filename: '0000000${position + 1}.jpg',
          ext: '.jpg',
          size: 1024,
          mtimeMs: 1,
          url: '/img/1000001/$position',
        ),
    ],
    spiderInfo: SpiderInfoVo.empty,
  );
}
