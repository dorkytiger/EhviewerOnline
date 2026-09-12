import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/ui/provider/auth_provider.dart';
import '../../model/vo/facets_vo.dart';
import '../../service/library_service.dart';

/// 筛选候选项。
///
/// watch 会话状态：每个读接口都由会话把关，登录/退出都会改变可见的候选集，
/// 不重取就会留下旧的计数。`authProvider` 是 runtime 只读状态，跨模块读它是
/// 全局规范明确允许的。
final facetsProvider = FutureProvider<FacetsVo>((ref) async {
  ref.watch(authProvider.select((s) => s.status));
  final result = await ref.watch(libraryServiceProvider).facets();
  // 把 Result 收敛成 AsyncValue 的三态：失败在这里转成 error 状态，交给
  // CustomErrorWidget 展示，异常不越过 provider 边界。
  return result.fold((facets) => facets, (error) => throw error);
});
