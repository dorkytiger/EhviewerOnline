import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';
import 'package:go_router/go_router.dart';

/// 三个根目的地（图库 / 下载 / 设置）的底部导航。
///
/// 只有这两个页面走底部导航；详情页和阅读器是 push 上来的，会盖住导航栏
/// ——这正是阅读时想要的行为，也让返回手势符合直觉。
class AppShellView extends StatelessWidget {
  const AppShellView({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return FScaffold(
      // 子页面自己决定留白：图库是列表、设置是分区块卡片，统一加 padding
      // 会让两边都错。
      childPad: false,
      footer: FBottomNavigationBar(
        index: navigationShell.currentIndex,
        onChange: (index) => navigationShell.goBranch(
          index,
          // 点当前目的地回到它的根页面，跟平台惯例一致。
          initialLocation: index == navigationShell.currentIndex,
        ),
        children: const [
          FBottomNavigationBarItem(
            icon: Icon(FLucideIcons.images),
            label: Text('图库'),
          ),
          FBottomNavigationBarItem(
            icon: Icon(FLucideIcons.folderDown),
            label: Text('下载'),
          ),
          FBottomNavigationBarItem(
            icon: Icon(FLucideIcons.settings),
            label: Text('设置'),
          ),
        ],
      ),
      child: navigationShell,
    );
  }
}
