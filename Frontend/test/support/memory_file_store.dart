import 'dart:typed_data';

import 'package:ehviewer_online/core/service/file_store.dart';

/// 内存里的假 [FileStore]，给不关心真实文件系统的用例共用。
///
/// 比直接 mock 更值的地方在于它模拟了**目录**：下载模块靠 `isDirectory` 找画廊目录，
/// 假实现只报文件就等于把那条契约测成了空。
///
/// `dart:io` 与 `path_provider` 在 widget 测试里都不能用：真实平台通道的回复要靠事件
/// 循环驱动，而 `testWidgets` 跑在假时钟里，一次 `await` 平台通道就会永远挂住，表现
/// 为 `pumpAndSettle timed out`。所以任何在构建路径上碰文件的 widget 测试都必须换成
/// 这个假实现。
class MemoryFileStore implements FileStore {
  MemoryFileStore({this.supported = true, this.cacheRoot = '/cache'});

  @override
  final bool supported;

  /// [cacheDirectory] 返回的路径；`null` 表示平台没有缓存目录。
  final String? cacheRoot;

  final Map<String, Uint8List> files = {};

  /// 所有存在过的目录。
  final Set<String> directories = {};

  final Map<String, int> modifiedMs = {};
  int _clock = 1;

  /// 让后续写入的修改时间递增，淘汰顺序才可判定。
  void tick() => _clock++;

  void _markParents(String path) {
    final parts = path.split('/');
    for (var i = 1; i < parts.length - 1; i++) {
      directories.add(parts.take(i + 1).join('/'));
    }
  }

  @override
  Future<String?> cacheDirectory() async => supported ? cacheRoot : null;

  @override
  Future<String?> supportDirectory() async => supported ? '/support' : null;

  @override
  Future<bool> exists(String path) async =>
      files.containsKey(path) || directories.contains(path);

  @override
  Future<Uint8List?> read(String path) async => files[path];

  @override
  Future<bool> write(String path, Uint8List bytes) async {
    if (!supported) return false;
    files[path] = bytes;
    modifiedMs[path] = _clock;
    _markParents(path);
    return true;
  }

  @override
  Future<bool> delete(String path) async {
    files.removeWhere((key, _) => key == path || key.startsWith('$path/'));
    directories.removeWhere((key) => key == path || key.startsWith('$path/'));
    modifiedMs.removeWhere((key, _) => key == path || key.startsWith('$path/'));
    return true;
  }

  @override
  Future<List<FileEntry>> list(String dir) async {
    final prefix = '$dir/';
    return [
      for (final entry in directories)
        if (entry.startsWith(prefix) && !entry.substring(prefix.length).contains('/'))
          FileEntry(path: entry, bytes: 0, modifiedMs: 0, isDirectory: true),
      for (final entry in files.entries)
        if (entry.key.startsWith(prefix) &&
            !entry.key.substring(prefix.length).contains('/'))
          FileEntry(
            path: entry.key,
            bytes: entry.value.length,
            modifiedMs: modifiedMs[entry.key] ?? 0,
            isDirectory: false,
          ),
    ];
  }

  @override
  Future<int> sizeBytes(String dir) async => files.entries
      .where((e) => e.key.startsWith('$dir/'))
      .fold<int>(0, (sum, e) => sum + e.value.length);
}
