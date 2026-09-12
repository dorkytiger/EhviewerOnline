import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../exception/global_exception.dart';
import '../util/result_util.dart';
import 'dio_provider.dart';
import 'file_store.dart';
import 'local_prefs.dart';

/// 封面缩略图的本地缓存：内存热点层 + 磁盘 LRU。
///
/// **不需要自己造失效协议。** 服务端已经为缩略图和原图发了
/// `Cache-Control: private, max-age=31536000, immutable` 和 ETag（见
/// `Backend/internal/httpapi`），而且封面 URL 里带 `?v=<mtime>`——封面一变 URL
/// 就变。所以「按 URL 做 key」本身就是正确的失效策略：旧 key 再也不会被请求，
/// 由 LRU 自然淘汰。
///
/// 两层各司其职：内存层让同一屏里的重复访问不必碰磁盘（也就不会重复解码），
/// 磁盘层让重启之后不必回源——走隧道/远程域名时这才是真正省流量的那一层。
///
/// Web 上没有文件系统，退化为纯内存（见 [FileStore.supported]）。
class ThumbnailCache {
  ThumbnailCache({
    required this.store,
    required this.fetch,
    required this.enabled,
    this.memoryEntries = _defaultMemoryEntries,
    this.budgetBytes = _defaultBudgetBytes,
  });

  final FileStore store;
  final Future<Result<Uint8List>> Function(String url) fetch;

  /// 内存里最多保留几张。够了：网格一屏通常几十张，再多只是占内存。
  final int memoryEntries;

  /// 磁盘缓存上限。480px 的 JPEG 缩略图约 20–40 KB，64 MiB 大约能放两千张封面。
  final int budgetBytes;

  /// 是否启用。关掉时读写缓存都不做，直接回源——这是设置页那个开关的语义。
  ///
  /// 不做成可变状态：开关变化时 [thumbnailCacheProvider] 会重建实例，磁盘层本来
  /// 就持久，内存层丢掉一次没有影响。
  final bool enabled;

  /// LRU：最近用过的在末尾（Dart 的 Map 按插入顺序迭代）。
  final Map<String, Uint8List> _memory = {};

  String? _cacheDir;
  bool _dirResolved = false;
  int? _diskBytes;

  static const int _defaultMemoryEntries = 200;
  static const int _defaultBudgetBytes = 64 * 1024 * 1024;
  static const String _subDir = 'thumbnails';

  /// 取一张图：内存 → 磁盘 → 网络。
  ///
  /// 只有**回源**的失败会成为错误；缓存的读写失败都当作未命中处理并继续回源——
  /// 缓存坏了不该让一次本来能成功的加载失败。
  Future<Result<Uint8List>> load(String url) async {
    if (!enabled) return fetch(url);

    final hot = _memory.remove(url);
    if (hot != null) {
      _memory[url] = hot; // 重新插入到末尾 = 标记为最近使用
      return Result.success(hot);
    }

    final path = await _pathFor(url);
    if (path != null) {
      final cold = await store.read(path);
      if (cold != null && cold.isNotEmpty) {
        _remember(url, cold);
        return Result.success(cold);
      }
    }

    final result = await fetch(url);
    final bytes = result.data;
    if (bytes != null && bytes.isNotEmpty) {
      // 写缓存是尽力而为：失败只意味着下次还要回源，不该把成功的加载变成失败。
      await _persist(url, bytes);
      _remember(url, bytes);
    }
    return result;
  }

  /// 是否有磁盘层。Web 没有文件系统（见 [FileStore.supported]），缓存只活在内存里，
  /// 占用永远是 0——UI 需要据此换一句诚实的文案，而不是显示「占用 0 B」。
  bool get persistent => store.supported;

  /// 缓存当前占用的字节数（仅磁盘层；内存层太小，不值得展示）。
  Future<int> sizeBytes() async {
    final dir = await _resolveDir();
    if (dir == null) return 0;
    return _diskBytes = await store.sizeBytes(dir);
  }

  /// 清空缓存。
  Future<Result<void>> clear() async {
    _memory.clear();
    final dir = await _resolveDir();
    if (dir == null) return Result.success(null);
    final ok = await store.delete(dir);
    _diskBytes = 0;
    if (!ok) {
      return Result.error(const LocalStorageException(message: '缓存清理失败'));
    }
    return Result.success(null);
  }

  void _remember(String url, Uint8List bytes) {
    _memory
      ..remove(url)
      ..[url] = bytes;
    while (_memory.length > memoryEntries) {
      _memory.remove(_memory.keys.first); // 最久未用
    }
  }

  /// 把字节写进磁盘，必要时按 LRU 淘汰。
  Future<void> _persist(String url, Uint8List bytes) async {
    final dir = await _resolveDir();
    if (dir == null) return;

    final path = '$dir/${_key(url)}.bin';
    if (!await store.write(path, bytes)) return;

    _diskBytes = (_diskBytes ?? await store.sizeBytes(dir)) + bytes.length;
    if (_diskBytes! > budgetBytes) await _evict(dir);
  }

  Future<void> _evict(String dir) async {
    final entries = await store.list(dir);
    final files = entries.where((e) => !e.isDirectory).toList()
      ..sort((a, b) => a.modifiedMs.compareTo(b.modifiedMs)); // 最旧的先删

    for (final file in files) {
      if ((_diskBytes ?? 0) <= budgetBytes) break;
      if (await store.delete(file.path)) {
        _diskBytes = (_diskBytes ?? 0) - file.bytes;
      }
    }
  }

  Future<String?> _pathFor(String url) async {
    final dir = await _resolveDir();
    return dir == null ? null : '$dir/${_key(url)}.bin';
  }

  Future<String?> _resolveDir() async {
    if (_dirResolved) return _cacheDir;
    _dirResolved = true;
    final root = await store.cacheDirectory();
    if (root == null) return _cacheDir = null;
    _cacheDir = '$root/$_subDir';
    return _cacheDir;
  }

  /// 缓存键：两条 32 位多项式哈希拼成的 16 位十六进制。
  ///
  /// 用它而不是 `String.hashCode`：后者不保证跨进程/跨平台稳定，而磁盘上的文件名
  /// 必须在重启后仍指向同一个文件——否则缓存永远命中不了，还会留下一堆孤儿文件。
  ///
  /// **不要换成 64 位 FNV。** `0xcbf29ce484222325` / `0xFFFFFFFFFFFFFFFF` 这类常量
  /// 在 Web 上直接编译不过（dart2js：can't be represented exactly in JavaScript），
  /// 而 Web 也要能构建。这里每一步的中间值都小于 2^37，在 double 的精确范围内，
  /// 所以 VM 与 Web 得到同一个键。两条不同底数的哈希合起来与 64 位哈希键空间相当。
  static String _key(String url) {
    var first = 0;
    var second = 0;
    for (final unit in utf8.encode(url)) {
      first = (first * 31 + unit) & 0xFFFFFFFF;
      second = (second * 131 + unit) & 0xFFFFFFFF;
    }
    return '${_hex8(first)}${_hex8(second)}';
  }

  static String _hex8(int value) => value.toRadixString(16).padLeft(8, '0');
}

/// 缩略图缓存的装配点。
///
/// 跟着设置里的开关走：`ref.watch(localPrefsProvider)` 让关掉开关时立刻生效，
/// 不必重启应用。
final thumbnailCacheProvider = Provider<ThumbnailCache>((ref) {
  final prefs = ref.watch(localPrefsProvider);
  final api = ref.watch(apiClientProvider);
  return ThumbnailCache(
    store: ref.watch(fileStoreProvider),
    fetch: api.getBytes,
    enabled: prefs.imageCacheEnabled,
  );
});
