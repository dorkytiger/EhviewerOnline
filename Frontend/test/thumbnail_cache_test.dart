import 'dart:convert';
import 'dart:typed_data';

import 'package:ehviewer_online/core/exception/global_exception.dart';
import 'package:ehviewer_online/core/service/file_store.dart';
import 'package:ehviewer_online/core/service/thumbnail_cache.dart';
import 'package:ehviewer_online/core/util/result_util.dart';
import 'package:flutter_test/flutter_test.dart';

/// [ThumbnailCache] 的行为测试。
///
/// 用一个内存里的假 [FileStore]，所以既能覆盖磁盘层的命中/淘汰逻辑，又不需要真
/// 的文件系统（也就不受测试环境限制）。
void main() {
  late _MemoryFileStore store;
  late int fetches;

  Future<Result<Uint8List>> fetch(String url) async {
    fetches++;
    return Result.success(Uint8List.fromList(utf8.encode('bytes-of:$url')));
  }

  ThumbnailCache build({bool enabled = true, int? budget}) => ThumbnailCache(
        store: store,
        fetch: fetch,
        enabled: enabled,
        budgetBytes: budget ?? 1024 * 1024,
      );

  setUp(() {
    store = _MemoryFileStore();
    fetches = 0;
  });

  test('首次访问回源，并写进磁盘与内存', () async {
    final cache = build();

    final first = await cache.load('http://h/thumb/1?v=1');
    expect(first.isSuccess, isTrue);
    expect(fetches, 1);

    // 第二次不再回源：内存层命中。
    await cache.load('http://h/thumb/1?v=1');
    expect(fetches, 1);
  });

  test('换一个实例仍能命中磁盘（跨重启的效果）', () async {
    await build().load('http://h/thumb/1?v=1');
    expect(fetches, 1);

    // 新实例 = 内存层为空，模拟重启。磁盘层还在。
    final afterRestart = build();
    final result = await afterRestart.load('http://h/thumb/1?v=1');

    expect(result.isSuccess, isTrue);
    expect(fetches, 1, reason: '磁盘命中不该回源——这正是缓存的意义');
  });

  test('URL 变了就当新资源（封面用 ?v=mtime 做失效）', () async {
    await build().load('http://h/thumb/1?v=1');
    await build().load('http://h/thumb/1?v=2');

    expect(fetches, 2, reason: '版本变化必须回源，否则会一直显示旧封面');
  });

  test('关掉开关后完全不碰缓存，只回源', () async {
    final cache = build(enabled: false);

    await cache.load('http://h/thumb/1?v=1');
    await cache.load('http://h/thumb/1?v=1');

    expect(fetches, 2, reason: '开关关闭时不该有内存层命中');
    expect(await cache.sizeBytes(), 0, reason: '开关关闭时不该写磁盘');
  });

  test('超过预算时淘汰最旧的，且总量回到预算内', () async {
    // 每条 20 字节左右，预算压到 100 字节 → 必须淘汰。
    final cache = build(budget: 100);
    for (var i = 0; i < 20; i++) {
      await cache.load('http://h/thumb/$i?v=1');
      // 让 mtime 递增，淘汰顺序才可判定。
      store.tick();
    }

    final size = await cache.sizeBytes();
    expect(size, lessThanOrEqualTo(100));
    // 最新的那条必须还在（否则淘汰策略把刚写的删了，等于白做）。
    final fresh = await build(budget: 100).load('http://h/thumb/19?v=1');
    expect(fresh.isSuccess, isTrue);
  });

  test('清除缓存后磁盘为空', () async {
    final cache = build();
    await cache.load('http://h/thumb/1?v=1');
    expect(await cache.sizeBytes(), greaterThan(0));

    final cleared = await cache.clear();

    expect(cleared.isSuccess, isTrue);
    expect(await cache.sizeBytes(), 0);
  });

  test('回源失败时如实返回错误，不写入缓存', () async {
    final failing = ThumbnailCache(
      store: store,
      fetch: (url) async => Result.error(const RemoteException(message: '网络断了')),
      enabled: true,
    );

    final result = await failing.load('http://h/thumb/1?v=1');

    expect(result.isError, isTrue);
    expect(result.error?.message, '网络断了');
    expect(await failing.sizeBytes(), 0);
  });

  test('Web（store 不支持）时退化为纯内存，功能不报错', () async {
    final webStore = _MemoryFileStore(supported: false, root: null);
    final cache = ThumbnailCache(
      store: webStore,
      fetch: fetch,
      enabled: true,
    );

    await cache.load('http://h/thumb/1?v=1');
    await cache.load('http://h/thumb/1?v=1');

    expect(fetches, 1, reason: '没有磁盘也要有内存层');
    expect(await cache.sizeBytes(), 0);
  });
}

/// 内存里的假文件系统。
class _MemoryFileStore implements FileStore {
  _MemoryFileStore({this.supported = true, this.root = '/cache'});

  @override
  final bool supported;

  final String? root;

  final Map<String, Uint8List> files = {};
  final Map<String, int> modified = {};
  int _clock = 1;

  /// 让后续写入的 mtime 递增，淘汰顺序才可判定。
  void tick() => _clock++;

  @override
  Future<String?> cacheDirectory() async => supported ? root : null;

  @override
  Future<String?> supportDirectory() async => supported ? '/support' : null;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<Uint8List?> read(String path) async => files[path];

  @override
  Future<bool> write(String path, Uint8List bytes) async {
    if (!supported) return false;
    files[path] = bytes;
    modified[path] = _clock;
    return true;
  }

  @override
  Future<bool> delete(String path) async {
    files.removeWhere((key, _) => key == path || key.startsWith('$path/'));
    modified.removeWhere((key, _) => key == path || key.startsWith('$path/'));
    return true;
  }

  @override
  Future<List<FileEntry>> list(String dir) async => [
        for (final entry in files.entries)
          if (entry.key.startsWith('$dir/'))
            FileEntry(
              path: entry.key,
              bytes: entry.value.length,
              modifiedMs: modified[entry.key] ?? 0,
              isDirectory: false,
            ),
      ];

  @override
  Future<int> sizeBytes(String dir) async => files.entries
      .where((e) => e.key.startsWith('$dir/'))
      .fold<int>(0, (sum, e) => sum + e.value.length);
}
