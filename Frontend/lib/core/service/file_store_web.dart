import 'dart:typed_data';

import 'file_store.dart';

/// [FileStore] 在 Web 上的降级实现。
///
/// 浏览器里没有应用私有文件系统，所以 [supported] 为 false：缩略图缓存退化为纯
/// 内存，离线下载直接告知"此平台不可用"。**不要**在这里用 IndexedDB 或 Cache API
/// 假装有文件系统——那会引入一整套只在 Web 上存在的代码路径，而下载功能在浏览器
/// 里的正确形态是"用浏览器自己的下载"，不是应用自己存。
FileStore createFileStore() => const WebFileStore();

class WebFileStore implements FileStore {
  const WebFileStore();

  @override
  bool get supported => false;

  @override
  Future<String?> cacheDirectory() async => null;

  @override
  Future<String?> supportDirectory() async => null;

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<Uint8List?> read(String path) async => null;

  @override
  Future<bool> write(String path, Uint8List bytes) async => false;

  /// 删除是幂等的：没有东西可删就等于已经删掉了。
  @override
  Future<bool> delete(String path) async => true;

  @override
  Future<List<FileEntry>> list(String dir) async => const [];

  @override
  Future<int> sizeBytes(String dir) async => 0;
}
