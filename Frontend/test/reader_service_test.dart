import 'package:ehviewer_online/feature/library/model/vo/gallery_detail_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/page_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/spider_info_vo.dart';
import 'package:ehviewer_online/feature/library/enum/availability.dart';
import 'package:ehviewer_online/feature/library/enum/meta_source.dart';
import 'package:ehviewer_online/feature/library/enum/title_source.dart';
import 'package:ehviewer_online/feature/reader/service/reader_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
