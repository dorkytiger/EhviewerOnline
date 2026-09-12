import 'package:ehviewer_online/core/util/url_util.dart';
import 'package:ehviewer_online/feature/library/enum/gallery_sort.dart';
import 'package:ehviewer_online/feature/library/enum/tag_dimension.dart';
import 'package:ehviewer_online/feature/library/model/state/library_filter_state.dart';
import 'package:ehviewer_online/feature/library/model/vo/facets_vo.dart';
import 'package:ehviewer_online/feature/library/model/vo/gallery_vo.dart';
import 'package:flutter_test/flutter_test.dart';

/// 筛选状态本身的测试。
///
/// [LibraryFilterState] 是标签语义的落点——一个维度是**集合**而不是单选，
/// 服务端对同维度内的值取 OR、维度之间取 AND。这些规则决定列表显示什么，
/// 所以值得在没有 widget、没有服务器的情况下钉住。
void main() {
  group('LibraryFilterState 标签', () {
    test('初始为空且没有生效的筛选', () {
      const filter = LibraryFilterState();
      expect(filter.isEmpty, isTrue);
      expect(filter.activeCount, 0);
      expect(filter.tagsOf(TagDimension.artist), isEmpty);
    });

    test('同维度选第二个值不会丢掉第一个', () {
      // 这正是这个功能的重点：选两个作者表示「任一」。
      // 若替换而不是累加，列表会被悄悄收窄成最后一次点击的结果。
      final filter = const LibraryFilterState()
          .toggleTag(TagDimension.artist, 'balmos')
          .toggleTag(TagDimension.artist, 'artdecade');

      expect(filter.tagsOf(TagDimension.artist), {'balmos', 'artdecade'});
      expect(filter.activeCount, 2);
      expect(filter.isEmpty, isFalse);
    });

    test('同一个值点两次会移除，并整个删掉该维度', () {
      final filter = const LibraryFilterState()
          .toggleTag(TagDimension.group, '黑曜石汉化组')
          .toggleTag(TagDimension.group, '黑曜石汉化组');

      expect(filter.tagsOf(TagDimension.group), isEmpty);
      // 空维度被直接移除，这样「没有标签筛选」始终只有一个判断方式，
      // 而不是「有些维度是空的」。
      expect(filter.tags.containsKey(TagDimension.group), isFalse);
      expect(filter.isEmpty, isTrue);
    });

    test('维度之间互不影响', () {
      final filter = const LibraryFilterState()
          .toggleTag(TagDimension.artist, 'LionkinEn')
          .toggleTag(TagDimension.series, 'warzard');

      expect(filter.tagsOf(TagDimension.artist), {'LionkinEn'});
      expect(filter.tagsOf(TagDimension.series), {'warzard'});
      expect(filter.activeCount, 2);
    });

    test('toQuery 为每个选中值输出一个重复参数', () {
      final query = const LibraryFilterState()
          .toggleTag(TagDimension.artist, 'b')
          .toggleTag(TagDimension.artist, 'a')
          .toggleTag(TagDimension.event, 'C85')
          .toQuery();

      // 已排序，所以同一组选择永远生成同一个 URL，也就绑定到同一个游标指纹。
      expect(query['artist'], ['a', 'b']);
      expect(query['event'], ['C85']);
      // 未选中的维度直接缺席，而不是「存在但为空」：空值会变成一个
      // 什么都匹配不到的筛选条件。
      expect(query.containsKey('group'), isFalse);
      expect(query['sort'], GallerySort.timeDesc.wire);
    });

    test('copyWith 改别的字段时保留标签', () {
      final filter =
          const LibraryFilterState().toggleTag(TagDimension.artist, 'x');
      final withSort = filter.copyWith(sort: GallerySort.title);

      expect(withSort.tagsOf(TagDimension.artist), {'x'});
      expect(withSort.sort, GallerySort.title);
    });
  });

  group('FacetsVo 解析', () {
    test('读取目录名推导出的维度及其 label', () {
      final facets = FacetsVo.fromJson(const {
        'labels': [
          {'value': '默认', 'count': 3},
        ],
        'artists': [
          {
            'value': 'koukyuu denim (futee)',
            'label': 'Koukyuu Denim (Futee)',
            'count': 2,
          },
        ],
        'groups': [
          {'value': '黑曜石汉化组', 'count': 1},
        ],
        'series': [
          {'value': 'warzard', 'label': 'Warzard', 'count': 2},
        ],
        'events': [
          {'value': 'c85', 'label': 'C85', 'count': 1},
        ],
        'editions': [
          {'value': 'digital', 'label': 'Digital', 'count': 5},
        ],
      });

      expect(facets.artists.single.display, 'Koukyuu Denim (Futee)');
      expect(facets.artists.single.value, 'koukyuu denim (futee)');
      expect(facets.artists.single.count, 2);
      // label 为空说明 value 本身就是该展示的拼写，这正是快照维度的情形。
      expect(facets.groups.single.display, '黑曜石汉化组');
      expect(facets.series.single.display, 'Warzard');
      expect(facets.events.single.display, 'C85');
      expect(facets.editions.single.display, 'Digital');
      expect(TagDimension.artist.of(facets), facets.artists);
    });

    test('缺失的维度解析为空而不是抛异常', () {
      // 早于「目录名推导标签」的服务端会完全省略这些字段。
      final facets = FacetsVo.fromJson(const {'labels': []});
      expect(facets.artists, isEmpty);
      expect(TagDimension.edition.of(facets), isEmpty);
    });
  });

  group('GalleryVo 标签', () {
    test('解析目录名推导出的标签列表', () {
      final gallery = GalleryVo.fromJson(const {
        'gid': 1080380,
        'title': '神龙大侠',
        'artists': ['balmos'],
        'groups': ['黑曜石汉化组'],
        'series': ['Kung Fu Panda'],
        'events': <String>[],
        'editions': <String>[],
      });

      expect(gallery.artists, ['balmos']);
      expect(gallery.groups, ['黑曜石汉化组']);
      expect(gallery.series, ['Kung Fu Panda']);
      expect(gallery.events, isEmpty);
      expect(gallery.editions, isEmpty);
      expect(gallery.tagsOf(TagDimension.artist), ['balmos']);
    });

    test('没有标签的画廊解析为空列表', () {
      final gallery = GalleryVo.fromJson(const {'gid': 1, 'title': 'plain'});
      expect(gallery.artists, isEmpty);
      expect(gallery.editions, isEmpty);
    });
  });

  group('normalizeBaseUrl', () {
    test('去掉末尾斜杠与首尾空白', () {
      expect(normalizeBaseUrl('  http://127.0.0.1:8080/  '),
          'http://127.0.0.1:8080');
      expect(normalizeBaseUrl('https://example.com//'), 'https://example.com');
      expect(normalizeBaseUrl('http://a'), 'http://a');
    });
  });
}
