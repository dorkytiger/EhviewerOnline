import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/service/file_store.dart';
import '../../model/dto/download_page_dto.dart';
import '../../model/entity/download_manifest.dart';

/// 已下载画廊的**文件**边界：目录、清单、页文件。
///
/// 一个类只管这一个数据边界（`<support>/downloads` 这棵目录树），索引、状态、
/// 列表统计都不在这里——那些是别的边界的事（见 `DownloadRepository`）。
///
/// 所有方法都不抛异常：读失败与「不存在」在调用方看来都该是「没有本地副本」，
/// 上层据此回源或显示空态（见 [FileStore] 的契约）。
class DownloadFileLocalDatasource {
  DownloadFileLocalDatasource(this._store);

  final FileStore _store;

  static const String _rootName = 'downloads';
  static const String _manifestName = 'manifest.json';

  /// 记住解析出来的支撑目录。
  ///
  /// 阅读器每翻一页都要问一次「本机有没有这一页」，而 `supportDirectory()` 是一次
  /// 平台通道往返；不记住的话每页都白花一次。**只缓存非空结果**：失败（通道没就绪、
  /// 平台没有该目录）时下次重试，否则一次偶发失败会让整个会话都下不了东西。
  ///
  /// 清单本身刻意**不**缓存：它是磁盘上的事实，缓存它就必须处理失效，而失效写错
  /// 会导致读到错的一页——代价远大于读一次几十 KB 的 JSON。
  String? _supportRoot;

  /// 平台是否有文件系统。Web 上为 false，整条下载链路据此显示「此平台不支持」。
  bool get supported => _store.supported;

  /// 根目录路径；[create] 为真时顺带创建。
  Future<String?> rootDir({bool create = false}) async {
    if (!_store.supported) return null;
    final support = _supportRoot ?? await _store.supportDirectory();
    if (support == null) return null;
    _supportRoot = support;
    final root = '$support/$_rootName';
    if (create) {
      // 用一次写入把目录建出来：FileStore 只保证 write 会建父目录，没有 mkdir。
      // 写一个空文件是幂等的，而目录已经存在时不会有副作用。
      await _store.write('$root/.keep', Uint8List(0));
    }
    return root;
  }

  /// 单本画廊的目录。
  ///
  /// 只在 `$dir/.keep` 上写一次就够：`FileStore.write` 会创建整条父路径，所以根目录
  /// 也一并建出来了。反过来在根目录再写一个 `.keep` 会留下一个删不掉的残留文件
  /// ——删除单本时它不属于任何画廊，用户看到「删完了占用还在」。
  Future<String?> galleryDir(int gid, {bool create = false}) async {
    final root = await rootDir();
    if (root == null) return null;
    final dir = '$root/$gid';
    if (create) await _store.write('$dir/.keep', Uint8List(0));
    return dir;
  }

  /// 读清单；不存在或内容损坏时返回 null。
  ///
  /// 损坏当作不存在处理：一份解析不了的清单无法证明任何一页可用，而目录里的散页
  /// 文件也不会被阅读器采用（没有清单就没有身份记录可校验）。用户看到的「没下载」
  /// 与事实（读不了）一致。
  Future<DownloadManifest?> readManifest(int gid) async {
    final dir = await galleryDir(gid);
    if (dir == null) return null;
    final bytes = await _store.read('$dir/$_manifestName');
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return null;
      final manifest = DownloadManifest.fromJson(decoded);
      // gid 对不上说明目录被手工改过（或复制错了），不认。
      return manifest.gid == gid ? manifest : null;
    } on FormatException {
      return null;
    }
  }

  /// 写清单。返回是否成功——失败必须知道，否则下载会在「以为记下了」的状态下继续。
  Future<bool> writeManifest(DownloadManifest manifest) async {
    final dir = await galleryDir(manifest.gid, create: true);
    if (dir == null) return false;
    final json = jsonEncode(manifest.toJson());
    return _store.write('$dir/$_manifestName', Uint8List.fromList(utf8.encode(json)));
  }

  /// 所有已下载画廊的 gid，升序。
  ///
  /// 以**目录名**为依据而不是清单：没有清单的目录要能出现在管理列表里（用户看得见
  /// 才能删掉它），所以这一层只认目录，清单缺失在 repository 里被表达成「未完成」。
  Future<List<int>> listedGids() async {
    final root = await rootDir();
    if (root == null) return const [];
    final entries = await _store.list(root);
    final gids = <int>[];
    for (final entry in entries) {
      if (!entry.isDirectory) continue;
      final gid = int.tryParse(_baseName(entry.path));
      if (gid != null) gids.add(gid);
    }
    gids.sort();
    return gids;
  }

  /// 读某一页的原始字节；没有时返回 null。
  Future<Uint8List?> readPage(int gid, DownloadPageDto page) async {
    final dir = await galleryDir(gid);
    if (dir == null) return null;
    return _store.read('$dir/${pageFileName(page)}');
  }

  /// 写某一页。返回是否成功。
  Future<bool> writePage(int gid, DownloadPageDto page, Uint8List bytes) async {
    final dir = await galleryDir(gid, create: true);
    if (dir == null) return false;
    return _store.write('$dir/${pageFileName(page)}', bytes);
  }

  /// 目录里现存的页文件名集合。
  ///
  /// 一次遍历拿到全部，用于断点续传判定与收尾清理——逐页 `exists` 在 700 页的画廊
  /// 上就是 700 次系统调用，而这里只需要一次。
  Future<Set<String>> pageFileNames(int gid) async {
    final dir = await galleryDir(gid);
    if (dir == null) return const {};
    final entries = await _store.list(dir);
    return {
      for (final entry in entries)
        if (!entry.isDirectory && _pageName.hasMatch(_baseName(entry.path)))
          _baseName(entry.path),
    };
  }

  /// 删掉不属于 [keep] 的页文件，返回删除的文件数。
  ///
  /// 收尾用：画廊在服务端缩水后，旧的多余文件会一直占着空间，而占用是用户看得见的
  /// 数字——留着它等于让「已下载」比实际小。
  Future<int> deleteStalePages(int gid, Set<String> keep) async {
    final dir = await galleryDir(gid);
    if (dir == null) return 0;
    final entries = await _store.list(dir);
    var removed = 0;
    for (final entry in entries) {
      if (entry.isDirectory) continue;
      final name = _baseName(entry.path);
      if (!_pageName.hasMatch(name)) continue;
      if (keep.contains(name)) continue;
      if (await _store.delete(entry.path)) removed++;
    }
    return removed;
  }

  /// 删除整本画廊的目录。目录不存在也算成功（幂等）。
  Future<bool> deleteGallery(int gid) async {
    final dir = await galleryDir(gid);
    if (dir == null) return false;
    return _store.delete(dir);
  }

  /// 删除所有下载。
  Future<bool> deleteAll() async {
    final root = await rootDir();
    if (root == null) return false;
    return _store.delete(root);
  }

  /// 单本画廊的实测占用。
  Future<int> galleryBytes(int gid) async {
    final dir = await galleryDir(gid);
    if (dir == null) return 0;
    return _store.sizeBytes(dir);
  }

  /// 页文件在磁盘上的名字。
  ///
  /// 用**位置**而不是原始文件名：服务端的文件名不保证唯一、可能带路径分隔符或
  /// 平台非法字符，而位置是本地唯一的寻址方式。扩展名保留，这样文件在文件管理器
  /// 里仍然认得出来是什么。
  static String pageFileName(DownloadPageDto page) {
    final position = page.position.toString().padLeft(4, '0');
    return '$position${extensionOf(page.filename)}';
  }

  /// 页文件名的形状：`0007.jpg`。用于把页文件与清单、别的杂物区分开，
  /// 也是「这个目录里有什么」的唯一判据。
  static final RegExp _pageName = RegExp(r'^\d{4,}\.[a-z0-9]+$');

  /// 认不出扩展名时的后缀。
  static const String _fallbackExt = '.bin';

  /// 从原始文件名里取出可用的扩展名（带点，小写）；认不出来时返回 `.bin`。
  ///
  /// 公开是因为离线重建页信息时也要用同一个判断：文件名到扩展名的规则只能有一处，
  /// 否则「写到磁盘上的名字」和「离线读出来的名字」会不一致。
  static String extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0) return _fallbackExt;
    final ext = filename.substring(dot).toLowerCase();
    // 只接受规规矩矩的扩展名（`.jpg` / `.png` / `.webp`）；其余一律落到 `.bin`，
    // 免得把服务端的怪名字变成磁盘上的怪名字。
    final ok = ext.length >= 2 &&
        ext.length <= 6 &&
        RegExp(r'^\.[a-z0-9]+$').hasMatch(ext);
    return ok ? ext : _fallbackExt;
  }

  static String _baseName(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

/// 文件边界的装配点。与缩略图缓存共用同一个 [FileStore]。
final downloadFileLocalDatasourceProvider =
    Provider<DownloadFileLocalDatasource>((ref) {
  return DownloadFileLocalDatasource(ref.watch(fileStoreProvider));
});
