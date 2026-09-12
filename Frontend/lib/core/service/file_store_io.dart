import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'file_store.dart';

/// [FileStore] 的原生实现（`dart:io` + `path_provider`）。
///
/// 这个文件**只在有 dart:io 的平台被编译进去**（见 `file_store.dart` 的条件导入）。
FileStore createFileStore() => const IoFileStore();

class IoFileStore implements FileStore {
  const IoFileStore();

  @override
  bool get supported => true;

  @override
  Future<String?> cacheDirectory() async {
    try {
      // cache 目录：系统在空间紧张时可以清理它，对缩略图缓存来说语义正好。
      return (await getApplicationCacheDirectory()).path;
    } on Exception {
      return null;
    }
  }

  @override
  Future<String?> supportDirectory() async {
    try {
      // support 目录：属于应用、系统不会自动清理，用来放用户主动下载的内容。
      return (await getApplicationSupportDirectory()).path;
    } on Exception {
      return null;
    }
  }

  @override
  Future<bool> exists(String path) async =>
      await FileSystemEntity.type(path) != FileSystemEntityType.notFound;

  @override
  Future<Uint8List?> read(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<bool> write(String path, Uint8List bytes) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<bool> delete(String path) async {
    try {
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.notFound) return true; // 幂等
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<List<FileEntry>> list(String dir) async {
    try {
      final directory = Directory(dir);
      if (!await directory.exists()) return const [];
      final out = <FileEntry>[];
      await for (final entity in directory.list(followLinks: false)) {
        final stat = await entity.stat();
        out.add(FileEntry(
          path: entity.path,
          bytes: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
          isDirectory: entity is Directory,
        ));
      }
      return out;
    } on FileSystemException {
      return const [];
    }
  }

  @override
  Future<int> sizeBytes(String dir) async {
    try {
      final directory = Directory(dir);
      if (!await directory.exists()) return 0;
      var total = 0;
      await for (final entity in directory.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } on FileSystemException {
          // 并发删除（例如用户同时点了"清除"）不该让整次统计失败。
        }
      }
      return total;
    } on FileSystemException {
      return 0;
    }
  }
}
