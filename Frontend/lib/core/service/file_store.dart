import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

// 默认用 Web 实现，**只要平台有 dart:io 就换成 io 实现**。
//
// 反过来的写法（默认 io）会让 Web 构建直接失败：Web 上根本没有 dart:io 这个库，
// 而 `dart:io` 是不能被"运行时判断"绕开的——它必须不出现在 Web 的依赖图里。
import 'file_store_web.dart' if (dart.library.io) 'file_store_io.dart' as impl;

/// 目录条目的一个快照。
///
/// 用普通类型而不是 `FileSystemEntity`：后者来自 `dart:io`，一暴露就把平台差异
/// 泄漏到了上层（以及 Web 构建）。
class FileEntry {
  const FileEntry({
    required this.path,
    required this.bytes,
    required this.modifiedMs,
    required this.isDirectory,
  });

  final String path;
  final int bytes;
  final int modifiedMs;
  final bool isDirectory;
}

/// 应用私有文件存取。
///
/// 抽成接口是因为 `dart:io` **不能出现在 Web 构建里**。把文件操作集中到条件导入
/// 的两个实现之后，上层的缩略图缓存与离线下载只剩平台无关逻辑，Web 上自动降级。
///
/// 所有方法都不抛异常：失败以返回值表达（false / null / 空表），调用方据此给出
/// 三态里的错误态。
abstract interface class FileStore {
  /// Web 上没有文件系统。为 false 时两个目录方法都返回 null，调用方据此退化为
  /// 内存实现或提示"此平台不可用"。
  bool get supported;

  /// 可被系统回收的缓存目录（缩略图缓存用）。系统清掉它是正常行为，不是故障。
  Future<String?> cacheDirectory();

  /// 持久保存用户数据的目录（离线下载用）。系统不会自动清理它——这正是下载与
  /// 缓存的区别：缓存可以消失，用户下载的东西不能。
  Future<String?> supportDirectory();

  Future<bool> exists(String path);

  /// 读取整个文件；不存在或读失败时返回 null。
  Future<Uint8List?> read(String path);

  /// 写入文件，父目录不存在则创建。返回是否成功。
  Future<bool> write(String path, Uint8List bytes);

  /// 递归删除文件或目录。目标不存在也算成功（幂等）。
  Future<bool> delete(String path);

  /// 列出**一层**目录下的条目；目录不存在时返回空表。
  Future<List<FileEntry>> list(String dir);

  /// 目录树的字节总和；不存在时返回 0。
  Future<int> sizeBytes(String dir);
}

/// 文件存取的装配点。
final fileStoreProvider = Provider<FileStore>((ref) => impl.createFileStore());
