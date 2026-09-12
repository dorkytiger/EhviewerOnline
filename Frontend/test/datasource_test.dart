import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ehviewer_online/common/config/app_config.dart';
import 'package:ehviewer_online/core/exception/global_exception.dart';
import 'package:ehviewer_online/core/service/api_client.dart';
import 'package:ehviewer_online/core/service/session_store.dart';
import 'package:ehviewer_online/core/util/result_util.dart';
import 'package:ehviewer_online/feature/auth/datasource/remote/auth_remote_datasource.dart';
import 'package:ehviewer_online/feature/library/datasource/remote/library_remote_datasource.dart';
import 'package:ehviewer_online/feature/library/enum/availability.dart';
import 'package:ehviewer_online/feature/library/enum/gallery_anomaly.dart';
import 'package:ehviewer_online/feature/library/enum/gallery_sort.dart';
import 'package:ehviewer_online/feature/library/enum/meta_source.dart';
import 'package:ehviewer_online/feature/library/enum/tag_dimension.dart';
import 'package:ehviewer_online/feature/library/enum/title_source.dart';
import 'package:ehviewer_online/feature/library/model/state/library_filter_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// datasource 层的契约测试：路径、查询参数编码、响应解析与错误透传。
///
/// 仍然跑真实 socket + 真实 Dio（见 `api_client_test.dart` 的传输层测试），
/// 因为这一层最容易出错的地方恰恰是「Dio 实际把查询参数编码成了什么」——
/// 标签筛选靠重复参数表达 OR，编码错了服务端只会返回空列表，不会报错。
/// fixture 抄自真实 ehviewer-webd 响应。
void main() {
  late SessionStore session;

  setUp(() async {
    // 每个用例一份全新存储，用例之间不通过会话互相影响，可以单独运行、乱序运行。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    session = SessionStore(await SharedPreferences.getInstance());
  });

  ApiClient newClient(String baseUrl) =>
      ApiClient(baseUrl: baseUrl, dio: Dio(), session: session);

  /// 取出一次预期失败的错误；成功则直接让用例失败。
  GlobalException failureOf<T>(Result<T> result) {
    expect(result.isError, isTrue, reason: '预期失败，实际成功：${result.data}');
    return result.error!;
  }

  group('LibraryRemoteDatasource 列表', () {
    test('解析 /api/v1/galleries 的完整响应', () async {
      String? seenPath;
      final server = await _serve({
        '/api/v1/galleries': (request) {
          seenPath = request.url.path;
          return _json(_galleryList);
        },
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final result = await datasource.fetchGalleries(
        filter: const LibraryFilterState(),
      );

      expect(seenPath, '/api/v1/galleries');
      expect(result.isSuccess, isTrue, reason: result.error?.message);
      final page = result.data!;
      expect(page.total, 2);
      expect(page.items, hasLength(2));
      expect(page.nextCursor, 'CURSOR1');
      expect(page.limit, 60);
      expect(page.indexedAtMs, 1789132082438);
      // 元数据的新鲜度只到快照时间为止，UI 会展示它；解析层必须原样带上来。
      expect(page.snapshotAtMs, 1789132065910);

      final first = page.items.first;
      expect(first.gid, 1234567);
      expect(first.title, 'Sample Gallery One');
      expect(first.titleJpn, 'サンプルギャラリー');
      // 标题是从目录名清洗出来的，不是真实标题，UI 要据此标注。
      expect(first.titleSource, TitleSource.dirname);
      expect(first.availability, Availability.ok);
      expect(first.metaSource, MetaSource.localOnly);
      expect(first.onDisk, isTrue);
      expect(first.pagesFound, 5);
      expect(first.isReadable, isTrue);
      expect(first.anomalies, isEmpty);
      expect(first.coverUrl, '/thumb/1234567?v=1789132065867');

      // 目录名推导出的标签字段。
      expect(first.artists, ['balmos']);
      expect(first.groups, ['黑曜石汉化组']);
      expect(first.series, ['Kung Fu Panda']);
      expect(first.events, isEmpty);
      expect(first.editions, ['Digital']);
      expect(first.tagsOf(TagDimension.artist), ['balmos']);

      final second = page.items[1];
      expect(second.availability, Availability.degraded);
      expect(second.simpleLanguage, 'ZH');
      expect(second.label, '画集');
      expect(second.rating, 3.0);
      expect(second.events, ['C85']);
      expect(second.anomalies, hasLength(1));
      expect(second.anomalies.first.code, GalleryAnomaly.pageCountMismatch);
      expect(second.anomalies.first.description, isNotEmpty);
      // 声明 9 页、找到 2 页 → 缺 7 页；这个数是从元数据算出来的，服务端不发。
      expect(second.missingPageCount, 7);
      expect(second.hasSevereAnomaly, isFalse, reason: '页数不一致会提示，但不必打断阅读');
    });

    test('标签筛选编码成重复参数 ?artist=a&artist=b', () async {
      Uri? seen;
      final server = await _serve({
        '/api/v1/galleries': (request) {
          seen = request.url;
          return _json({'items': <Object>[], 'total': 0});
        },
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final filter =
          const LibraryFilterState(
                text: 'chinese',
                label: '默认',
                language: 'ZH',
                category: 1,
                availability: Availability.degraded,
                sort: GallerySort.title,
              )
              .toggleTag(TagDimension.artist, 'b')
              .toggleTag(TagDimension.artist, 'a')
              .toggleTag(TagDimension.group, '黑曜石汉化组');

      final result = await datasource.fetchGalleries(
        filter: filter,
        cursor: 'abc.def',
        limit: 25,
      );

      expect(result.isSuccess, isTrue, reason: result.error?.message);
      // 服务端在同一维度内取 OR，靠的就是重复参数。编码成 `artist[]=a&artist[]=b`
      // 或 `artist=a,b` 都不会报错，只会让筛选静默匹配不到东西。
      expect(seen!.queryParametersAll['artist'], ['a', 'b']);
      expect(seen!.query, contains('artist=a&artist=b'));
      expect(seen!.queryParametersAll['group'], ['黑曜石汉化组']);
      expect(seen!.queryParameters['q'], 'chinese');
      expect(seen!.queryParameters['label'], '默认');
      expect(seen!.queryParameters['language'], 'ZH');
      expect(seen!.queryParameters['category'], '1');
      expect(seen!.queryParameters['availability'], 'degraded');
      expect(seen!.queryParameters['sort'], 'title');
      expect(seen!.queryParameters['limit'], '25');
      expect(seen!.queryParameters['cursor'], 'abc.def');
    });

    test('空筛选不发空串参数，只发默认排序与分页', () async {
      Uri? seen;
      final server = await _serve({
        '/api/v1/galleries': (request) {
          seen = request.url;
          return _json({'items': <Object>[], 'total': 0});
        },
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      await datasource.fetchGalleries(filter: const LibraryFilterState());

      final query = seen!.queryParameters;
      // 空串是一个真实（且匹配不到任何东西）的筛选值，绝不能发出去。
      expect(query.containsKey('q'), isFalse);
      expect(query.containsKey('label'), isFalse);
      expect(query.containsKey('language'), isFalse);
      expect(query.containsKey('category'), isFalse);
      expect(query.containsKey('availability'), isFalse);
      expect(query.containsKey('artist'), isFalse);
      expect(query.containsKey('group'), isFalse);
      // 首页没有游标：空游标会让服务端以为要接着某个指纹分页。
      expect(query.containsKey('cursor'), isFalse);
      expect(query['sort'], 'time_desc');
      expect(query['limit'], '${AppConfig.pageSize}');
    });

    test('items 为 null 时当成空列表，不让整页崩掉', () async {
      final server = await _serve({
        '/api/v1/galleries': (_) => _json({'items': null, 'total': 0}),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final result = await datasource.fetchGalleries(
        filter: const LibraryFilterState(),
      );

      expect(result.isSuccess, isTrue);
      expect(result.data!.items, isEmpty);
      expect(result.data!.total, 0);
    });

    test('未知 availability 落到 unknown 而不是「可读」', () async {
      final server = await _serve({
        '/api/v1/galleries': (_) => _json({
          'items': [
            {'gid': 1, 'title': 'x', 'availability': 'weird_new_value'},
          ],
          'total': 1,
        }),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final page = (await datasource.fetchGalleries(
        filter: const LibraryFilterState(),
      )).data!;

      // 把「不知道」显示成「可读」比显示成「未知」危险得多。
      expect(page.items.single.availability, Availability.unknown);
      expect(page.items.single.availability.label, '未知');
    });

    test('未知 anomaly code 原样展示且不算严重', () async {
      final server = await _serve({
        '/api/v1/galleries': (_) => _json({
          'items': [
            {
              'gid': 1,
              'title': 'x',
              'anomalies': ['something_new_from_a_newer_server'],
              'availability': 'degraded',
              'on_disk': true,
              'pages_found': 1,
            },
          ],
          'total': 1,
        }),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final anomaly = (await datasource.fetchGalleries(
        filter: const LibraryFilterState(),
      )).data!.items.single.anomalies.single;

      // 更新的服务端不能让一个问题在界面上消失，所以未知 code 照原样显示。
      expect(anomaly.code, 'something_new_from_a_newer_server');
      expect(anomaly.description, 'something_new_from_a_newer_server');
      expect(anomaly.isSevere, isFalse);
    });

    test('数字以字符串下发时做兼容转换', () async {
      final server = await _serve({
        '/api/v1/galleries': (_) => _json({
          'items': [
            {
              'gid': '1234567',
              'title': 'x',
              'pages_found': '5',
              'rating': '4.5',
            },
          ],
          'total': 1,
        }),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final gallery = (await datasource.fetchGalleries(
        filter: const LibraryFilterState(),
      )).data!.items.single;

      // 类型宽松只在 `json_coerce.dart` 做一次：代理或服务端版本差异不该让
      // 整个列表页挂掉。
      expect(gallery.gid, 1234567);
      expect(gallery.pagesFound, 5);
      expect(gallery.rating, 4.5);
    });

    test('缺失的可选字段退化成安全默认值', () async {
      final server = await _serve({
        '/api/v1/galleries': (_) => _json({
          'items': [
            {'gid': 1},
          ],
          'total': 1,
        }),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final gallery = (await datasource.fetchGalleries(
        filter: const LibraryFilterState(),
      )).data!.items.single;

      expect(gallery.title, isEmpty);
      // 兜底一个标题，紧凑布局才不会渲染出空行。
      expect(gallery.displayTitle, '#1');
      expect(gallery.isReadable, isFalse);
      expect(gallery.onDisk, isFalse);
      expect(gallery.anomalies, isEmpty);
      expect(gallery.availability, Availability.unknown);
      expect(gallery.titleSource, TitleSource.unknown);
      expect(gallery.metaSource, MetaSource.unknown);
      // 没有元数据时「声明了多少页」是未知，而不是 0；不能报一个假的缺页数。
      expect(gallery.missingPageCount, isNull);
    });
  });

  group('LibraryRemoteDatasource 详情', () {
    test('GET /api/v1/galleries/{gid} 解析页列表与 .ehviewer 元数据', () async {
      String? seenPath;
      final server = await _serve({
        '/api/v1/galleries/1234567': (request) {
          seenPath = request.url.path;
          return _json(_galleryDetail);
        },
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final result = await datasource.fetchGallery(1234567);

      expect(seenPath, '/api/v1/galleries/1234567');
      expect(result.isSuccess, isTrue, reason: result.error?.message);
      final detail = result.data!;
      expect(detail.gallery.gid, 1234567);
      expect(detail.gallery.artists, ['balmos']);

      // index 是 0 基、文件名是 1 基，阅读器两者都要用，不能顺手归一化。
      expect(detail.pagesDetail, hasLength(2));
      expect(detail.pagesDetail.first.index, 0);
      expect(detail.pagesDetail.first.filename, '00000001.png');
      expect(detail.pagesDetail.first.ext, '.png');
      expect(detail.pagesDetail.first.size, 105);
      expect(detail.pagesDetail.first.url, '/img/1234567/0');
      expect(detail.pagesDetail.last.index, 1);

      expect(detail.spiderInfo.present, isTrue);
      expect(detail.spiderInfo.version, 2);
      expect(detail.spiderInfo.startPage, 0);
      expect(detail.spiderInfo.previewPages, 1);
      expect(detail.spiderInfo.previewPerPage, 20);
      expect(detail.spiderInfo.pages, 2);

      // 同一排序下的相邻项；0 表示没有相邻（服务端 omitempty）。
      expect(detail.prevGid, 0);
      expect(detail.nextGid, 1234568);
    });

    test('缺少 spider_info 时不伪造元数据', () async {
      final server = await _serve({
        '/api/v1/galleries/1': (_) => _json({
          'gid': 1,
          'title': 'No Metadata',
          'pages_detail': <Object>[],
        }),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final result = await datasource.fetchGallery(1);

      expect(result.isSuccess, isTrue);
      final detail = result.data!;
      expect(detail.spiderInfo.present, isFalse);
      expect(detail.spiderInfo.version, 0);
      expect(detail.spiderInfo.pages, 0);
      expect(detail.pagesDetail, isEmpty);
    });

    test('服务端 404 原样透传 Result.error，不在这里改文案', () async {
      final server = await _serve({
        '/api/v1/galleries/999': (_) => _json({
          'error': {'code': 'not_found', 'message': 'no such gallery'},
        }, status: 404),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final result = await datasource.fetchGallery(999);

      final error = failureOf(result);
      expect(error, isA<RemoteException>());
      expect((error as RemoteException).statusCode, 404);
      // 文案由传输层按已知 code 翻译，datasource 不做二次包装。
      expect(error.message, '未找到该内容');
    });
  });

  group('LibraryRemoteDatasource facets 与 meta', () {
    test('facets 的快照维度与五个目录名推导维度都能读出', () async {
      String? seenPath;
      final server = await _serve({
        '/api/v1/facets': (request) {
          seenPath = request.url.path;
          return _json(_facets);
        },
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final result = await datasource.fetchFacets();

      expect(seenPath, '/api/v1/facets');
      expect(result.isSuccess, isTrue, reason: result.error?.message);
      final facets = result.data!;

      // 快照维度：value 就是展示值，服务端不发 label。
      expect(facets.labels, hasLength(2));
      expect(facets.labels.first.value, '默认');
      expect(facets.labels.first.count, 4);
      expect(facets.languages.single.value, 'ZH');
      expect(facets.categories.single.value, '1');
      expect(facets.availability.single.value, 'ok');

      // 目录名推导维度：value 是折叠后的键，label 是库里真实用过的拼写；
      // 只有大小写差异的拼写被合并成一个候选项。
      expect(facets.artists, hasLength(2));
      expect(facets.artists.first.value, 'koukyuu denim (futee)');
      expect(facets.artists.first.label, 'Koukyuu Denim (Futee)');
      expect(facets.artists.first.count, 2);
      expect(facets.artists.first.display, 'Koukyuu Denim (Futee)');

      // label 缺失（快照维度，或该维度只有一种拼写）时退回 value。
      expect(facets.groups.single.value, '黑曜石汉化组');
      expect(facets.groups.single.label, isEmpty);
      expect(facets.groups.single.display, '黑曜石汉化组');
      expect(facets.series.single.value, 'warzard');
      expect(facets.series.single.display, 'Warzard');
      expect(facets.events.single.value, 'c85');
      expect(facets.events.single.display, 'C85');
      expect(facets.editions.single.value, 'digital');
      expect(facets.editions.single.display, 'Digital');

      // 每个维度枚举都要能从 FacetsVo 里取到自己那份，筛选面板靠这个分发。
      expect(TagDimension.artist.of(facets), facets.artists);
      expect(TagDimension.group.of(facets), facets.groups);
      expect(TagDimension.series.of(facets), facets.series);
      expect(TagDimension.event.of(facets), facets.events);
      expect(TagDimension.edition.of(facets), facets.editions);
    });

    test('facets 省略的维度解析为空而不是报错', () async {
      final server = await _serve({
        '/api/v1/facets': (_) => _json({'labels': <Object>[]}),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final facets = (await datasource.fetchFacets()).data!;

      // 早于「目录名推导标签」的服务端会完全省略这些字段。
      expect(facets.artists, isEmpty);
      expect(facets.groups, isEmpty);
      expect(facets.series, isEmpty);
      expect(facets.events, isEmpty);
      expect(TagDimension.edition.of(facets), isEmpty);
    });

    test('GET /api/v1/meta 解析索引统计与功能开关', () async {
      String? seenPath;
      final server = await _serve({
        '/api/v1/meta': (request) {
          seenPath = request.url.path;
          return _json(_serverMeta);
        },
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final result = await datasource.fetchMeta();

      expect(seenPath, '/api/v1/meta');
      expect(result.isSuccess, isTrue, reason: result.error?.message);
      final meta = result.data!;
      expect(meta.version, '0.1.0');
      expect(meta.serverTimeMs, 1789132082438);
      expect(meta.galleries, 7);
      expect(meta.onDisk, 6);
      expect(meta.missing, 1);
      expect(meta.degraded, 3);
      expect(meta.pages, 19);
      expect(meta.totalBytes, 1995);
      expect(meta.skippedDirs, 2);
      expect(meta.snapshotAtMs, 1789132065910);
      expect(meta.snapshotFile, '20240101120000.db');
      expect(meta.indexedAtMs, 1789132082438);
      expect(meta.warnings, isEmpty);

      // 快照里没有 Gallery_Tags 表，标签筛选必须被如实标成不支持：UI 据此
      // 隐藏控件，而不是给出一个永远匹配不到任何东西的筛选。
      expect(meta.supportsTags, isFalse);
      expect(meta.supportsThumbnails, isTrue);
      expect(meta.supportsSse, isFalse);
    });

    test('meta 请求失败时 Result.error 原样上传', () async {
      final server = await _serve({
        '/api/v1/meta': (_) => _json({
          'error': {'code': 'internal', 'message': 'cannot load index'},
        }, status: 500),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final error = failureOf(await datasource.fetchMeta());

      expect(error, isA<RemoteException>());
      expect((error as RemoteException).statusCode, 500);
      // `internal` 没有专门文案，保留服务端说法，不套一句泛化错误丢掉信息。
      expect(error.message, 'cannot load index');
    });
  });

  group('LibraryRemoteDatasource 图片', () {
    test('fetchImageBytes 拿到原始字节并带上会话 cookie', () async {
      await session.write('abc123.signature');
      final bytes = Uint8List.fromList(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
      ]);
      String? seenAccept;
      String? seenCookie;
      final server = await _serve({
        '/img/1234567/0': (request) {
          seenAccept = request.headers['accept'];
          seenCookie = request.headers['cookie'];
          return http.Response.bytes(
            bytes,
            200,
            headers: const {'content-type': 'image/png'},
          );
        },
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final result = await datasource.fetchImageBytes('/img/1234567/0');

      expect(result.isSuccess, isTrue, reason: result.error?.message);
      expect(result.data, orderedEquals(bytes));
      expect(seenAccept, 'image/*');
      // 本端没有 cookie jar，图片请求必须显式重放会话，否则整页图全部 401。
      expect(seenCookie, 'ehw_session=abc123.signature');
    });

    test('fetchImageBytes 遇到空响应体报 ParsingException', () async {
      final server = await _serve({
        '/img/1/0': (_) => http.Response.bytes(
          <int>[],
          200,
          headers: const {'content-type': 'image/png'},
        ),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = LibraryRemoteDatasource(client);

      final error = failureOf(await datasource.fetchImageBytes('/img/1/0'));

      // 0 字节会渲染成破图；明确报错，UI 才有机会显示占位并重试。
      expect(error, isA<ParsingException>());
      expect(error.message, '图片内容为空');
    });
  });

  group('AuthRemoteDatasource', () {
    test('login 发送 LoginRequest 的 JSON 并落盘会话', () async {
      String? seenMethod;
      String? seenPath;
      String? seenBody;
      String? seenCookie;
      final server = await _serve({
        '/api/v1/auth/login': (request) {
          seenMethod = request.method;
          seenPath = request.url.path;
          seenBody = request.body;
          seenCookie = request.headers['cookie'];
          return _json(
            {'authenticated': true, 'expires_in_secs': 2592000},
            headers: {
              'set-cookie': 'ehw_session=abc123.signature; HttpOnly; Secure; SameSite=Lax; Path=/',
            },
          );
        },
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = AuthRemoteDatasource(client);

      final result = await datasource.login('the-token');

      expect(result.isSuccess, isTrue, reason: result.error?.message);
      // 成功即成功：Result<void> 没有数据可取，响应体不是这一层关心的东西。
      expect(seenMethod, 'POST');
      expect(seenPath, '/api/v1/auth/login');
      // 请求体只能来自 LoginRequest.toJson()；手拼 Map 会在字段改名后静默错位。
      expect(jsonDecode(seenBody!), {'token': 'the-token'});
      expect(seenCookie, isNull, reason: '登录前没有会话可重放');
      // cookie 的捕获在 ApiClient 内部完成，datasource 不能再实现第二处——
      // 存两处就会出现「一处清了、另一处没清」的幽灵会话。
      expect(session.read(), 'abc123.signature');
    });

    test('login 收到 401 返回 UnauthorizedException 而不是抛异常', () async {
      final server = await _serve({
        '/api/v1/auth/login': (_) => _json({
          'error': {'code': 'unauthorized', 'message': 'invalid token'},
        }, status: 401),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = AuthRemoteDatasource(client);

      final result = await datasource.login('wrong');

      final error = failureOf(result);
      expect(error, isA<UnauthorizedException>());
      expect((error as UnauthorizedException).isAuthFailure, isTrue);
      // 失败的登录绝不能留下一个半截会话。
      expect(session.read(), isNull);
    });

    test('checkSession 读到 authenticated=true', () async {
      final server = await _serve({
        '/api/v1/auth/me': (_) =>
            _json({'authenticated': true, 'auth_mode': 'token'}),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = AuthRemoteDatasource(client);

      final result = await datasource.checkSession();

      expect(result.isSuccess, isTrue);
      expect(result.data, isTrue);
    });

    test('checkSession 读到 authenticated=false', () async {
      final server = await _serve({
        '/api/v1/auth/me': (_) => _json({'authenticated': false}),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = AuthRemoteDatasource(client);

      final result = await datasource.checkSession();

      expect(result.isSuccess, isTrue);
      expect(result.data, isFalse);
    });

    test('checkSession 把 401 当成答案 false，而不是失败', () async {
      final server = await _serve({
        '/api/v1/auth/me': (_) => _json({
          'error': {'code': 'unauthorized', 'message': 'no valid session'},
        }, status: 401),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = AuthRemoteDatasource(client);

      final result = await datasource.checkSession();

      // `/auth/me` 问的就是「当前会话有效吗」，401 是答案本身。把它当错误上报，
      // 全新安装的用户会在登录页看到「登录已过期，请重新登录」——一句话从一个
      // 从没登录过的人嘴里说出来毫无意义。
      expect(result.isSuccess, isTrue);
      expect(result.data, isFalse);
    });

    test('checkSession 响应缺少 authenticated 时是契约违约', () async {
      final server = await _serve({
        '/api/v1/auth/me': (_) => _json({'auth_mode': 'none'}),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = AuthRemoteDatasource(client);

      final error = failureOf(await datasource.checkSession());

      expect(error, isA<ParsingException>());
      // `authenticated` 没有安全的默认值：把缺失当成 false 会把「后端接口改坏了」
      // 伪装成「用户没登录」，于是所有人朝错误方向排查。解析失败必须点名字段。
      expect(error.message, contains('authenticated'));
    });

    test('logout POST 到 /api/v1/auth/logout', () async {
      String? seenMethod;
      String? seenPath;
      final server = await _serve({
        '/api/v1/auth/logout': (request) {
          seenMethod = request.method;
          seenPath = request.url.path;
          return _json({'authenticated': false});
        },
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = AuthRemoteDatasource(client);

      final result = await datasource.logout();

      expect(result.isSuccess, isTrue);
      expect(seenMethod, 'POST');
      expect(seenPath, '/api/v1/auth/logout');
    });

    test('logout 失败原样透传错误，本地会话不在这里清', () async {
      await session.write('abc123.signature');
      final server = await _serve({
        '/api/v1/auth/logout': (_) => _json({
          'error': {
            'code': 'internal',
            'message': 'cannot reach session store',
          },
        }, status: 500),
      });
      addTearDown(server.close);
      final client = newClient(server.baseUrl);
      addTearDown(client.close);
      final datasource = AuthRemoteDatasource(client);

      final error = failureOf(await datasource.logout());

      expect(error, isA<RemoteException>());
      // 「远端失败也要清本地」是 repository 的规则；datasource 顺手清一次会让
      // 同一条规则散落在两层，某天只剩一层被改到。
      expect(session.read(), 'abc123.signature');
    });
  });
}

// --- fixtures --------------------------------------------------------------

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// 抄自真实 `GET /api/v1/galleries` 响应，补上目录名推导出的标签字段。
final Map<String, Object> _galleryList = {
  'items': [
    {
      'gid': 1234567,
      'token': 'tok1',
      'title': 'Sample Gallery One',
      'title_jpn': 'サンプルギャラリー',
      'title_source': 'dirname',
      'dir_name': '1234567-Sample Gallery One',
      'artists': ['balmos'],
      'groups': ['黑曜石汉化组'],
      'series': ['Kung Fu Panda'],
      'events': <String>[],
      'editions': ['Digital'],
      'category': 0,
      'posted': '2024-01-01 12:00:00',
      'uploader': 'uploader1',
      'rating': 0,
      'simple_language': '',
      'state': 0,
      'download_time_ms': 0,
      'pages_expected': 5,
      'pages_found': 5,
      'total_bytes': 525,
      'cover_url': '/thumb/1234567?v=1789132065867',
      'cover_kind': 'firstpage',
      'availability': 'ok',
      'anomalies': <String>[],
      'meta_source': 'local_only',
      'on_disk': true,
    },
    {
      'gid': 1234569,
      'token': 'tok3',
      'title': 'Interrupted Download',
      'title_source': 'db',
      'dir_name': '1234569-Interrupted Download',
      'artists': ['koukyuu denim (futee)'],
      'groups': <String>[],
      'series': <String>[],
      'events': ['C85'],
      'editions': <String>[],
      'category': 2,
      'rating': 3.0,
      'simple_language': 'ZH',
      'label': '画集',
      'state': 3,
      'download_time_ms': 1700000003000,
      'pages_expected': 9,
      'pages_found': 2,
      'total_bytes': 210,
      'cover_url': '/thumb/1234569?v=1789132065868',
      'cover_kind': 'firstpage',
      'availability': 'degraded',
      'anomalies': ['page_count_mismatch'],
      'meta_source': 'db',
      'on_disk': true,
    },
  ],
  'next_cursor': 'CURSOR1',
  'total': 2,
  'limit': 60,
  'indexed_at_ms': 1789132082438,
  'snapshot_at_ms': 1789132065910,
};

/// 抄自真实 `GET /api/v1/galleries/1234567` 响应。
final Map<String, Object> _galleryDetail = {
  'gid': 1234567,
  'token': 'tok1',
  'title': 'Sample Gallery One',
  'title_source': 'dirname',
  'dir_name': '1234567-Sample Gallery One',
  'artists': ['balmos'],
  'groups': ['黑曜石汉化组'],
  'series': ['Kung Fu Panda'],
  'events': <String>[],
  'editions': ['Digital'],
  'category': 0,
  'rating': 0,
  'pages_expected': 2,
  'pages_found': 2,
  'total_bytes': 210,
  'cover_url': '/thumb/1234567?v=1',
  'cover_kind': 'firstpage',
  'availability': 'ok',
  'anomalies': <String>[],
  'meta_source': 'local_only',
  'on_disk': true,
  'pages_detail': [
    {
      'index': 0,
      'filename': '00000001.png',
      'ext': '.png',
      'size': 105,
      'mtime_ms': 1789132065867,
      'url': '/img/1234567/0',
    },
    {
      'index': 1,
      'filename': '00000002.png',
      'ext': '.png',
      'size': 105,
      'mtime_ms': 1789132065868,
      'url': '/img/1234567/1',
    },
  ],
  'spider_info': {
    'present': true,
    'version': 2,
    'start_page': 0,
    'preview_pages': 1,
    'preview_per_page': 20,
    'pages': 2,
  },
  'prev_gid': 0,
  'next_gid': 1234568,
};

/// 抄自真实 `GET /api/v1/facets` 响应。
final Map<String, Object> _facets = {
  'labels': [
    {'value': '默认', 'count': 4},
    {'value': '画集', 'count': 1},
  ],
  'languages': [
    {'value': 'ZH', 'count': 2},
  ],
  'categories': [
    {'value': '1', 'count': 4},
  ],
  'availability': [
    {'value': 'ok', 'count': 3},
  ],
  'artists': [
    {
      'value': 'koukyuu denim (futee)',
      'label': 'Koukyuu Denim (Futee)',
      'count': 2,
    },
    {'value': 'balmos', 'label': 'balmos', 'count': 1},
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
};

/// 抄自真实 `GET /api/v1/meta` 响应。
final Map<String, Object> _serverMeta = {
  'version': '0.1.0',
  'server_time_ms': 1789132082438,
  'uptime_secs': 5,
  'index': {
    'galleries': 7,
    'on_disk': 6,
    'missing': 1,
    'degraded': 3,
    'anomalies': 3,
    'pages': 19,
    'total_bytes': 1995,
    'skipped_dirs': 2,
    'snapshot_at_ms': 1789132065910,
    'snapshot_path': '/srv/ehviewer-sync/EhViewer/data/20240101120000.db',
    'snapshot_count': 1,
    'indexed_at_ms': 1789132082438,
    'build_ms': 6,
  },
  'snapshot_file': '20240101120000.db',
  'roots': ['/srv/ehviewer-sync/EhViewer'],
  'warnings': <String>[],
  'skipped_dirs': <Object>[],
  'features': {'tags': false, 'thumbnails': true, 'sse': false},
  'thumb_stats': {'hits': 1, 'misses': 2, 'errors': 0},
};

// --- helpers ---------------------------------------------------------------

http.Response _json(
  Object body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => http.Response(
  jsonEncode(body),
  status,
  headers: {..._jsonHeaders, ...headers},
);

/// 按路径分发的测试服务器；未命中的路径返回 404。
///
/// 「客户端调了预期外的路径」因此会以一个明确的错误暴露（用例断言失败），
/// 而不是悄悄走到某个默认分支还看起来是绿的。
Future<_TestServer> _serve(
  Map<String, http.Response Function(http.Request request)> routes,
) => _startServer((request) async {
  final route = routes[request.url.path];
  if (route == null) {
    return _json({
      'error': {'code': 'not_found', 'message': 'no route ${request.url.path}'},
    }, status: 404);
  }
  return route(request);
});

class _TestServer {
  _TestServer(this._server);

  final HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

Future<_TestServer> _startServer(
  Future<http.Response> Function(http.Request request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final forwarded = http.Request(request.method, request.uri)..body = body;
      // HttpHeaders 没有 toMap()，forEach 是唯一的枚举方式；同名多值合并成
      // 一个头，和真实客户端发出的形态一致。
      request.headers.forEach((name, values) {
        forwarded.headers[name] = values.join(',');
      });

      final response = await handler(forwarded);
      request.response.statusCode = response.statusCode;
      response.headers.forEach((key, value) {
        // Set-Cookie 允许出现多次，必须 add；其余头是普通覆盖。
        if (key.toLowerCase() == 'set-cookie') {
          request.response.headers.add(key, value);
        } else {
          request.response.headers.set(key, value);
        }
      });
      request.response.add(response.bodyBytes);
      await request.response.close();
    } catch (_) {
      // 客户端取消/超时后连接已关闭，这时写响应会抛；不该变成未处理的异步异常。
      try {
        await request.response.close();
      } catch (_) {
        return;
      }
    }
  });
  return _TestServer(server);
}
