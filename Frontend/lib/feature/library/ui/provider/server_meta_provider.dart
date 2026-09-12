import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/ui/provider/auth_provider.dart';
import '../../model/vo/server_meta_vo.dart';
import '../../service/library_service.dart';

/// 服务端元数据：新鲜度、功能开关、索引统计与警告。
///
/// 设置页也要用它，所以**名字与路径是稳定契约**（`serverMetaProvider`）。
final serverMetaProvider = FutureProvider<ServerMetaVo>((ref) async {
  ref.watch(authProvider.select((s) => s.status));
  final result = await ref.watch(libraryServiceProvider).meta();
  return result.fold((meta) => meta, (error) => throw error);
});
