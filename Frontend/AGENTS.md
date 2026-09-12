# AGENTS.md — EhviewerOnline 前端补充

> 通用规范见**全局指令** `~/.dsh/AGENTS.md`（个人前端开发规范，十条铁律 + 分层 + 三态 + Result/GlobalException + 设计 token）。
> 本文件**只写本项目特有的东西**：技术栈版本、命令、目录映射、本项目已知的存量差距。
> 冲突裁决：本文件只能**补充/收紧**全局规范，不得放宽十条铁律。

---

## 1. 技术栈

| 项 | 值 |
| --- | --- |
| 框架 | Flutter / Dart，包名 `ehviewer_online` |
| 状态管理 | Riverpod 3（`flutter_riverpod`），**不用 codegen** |
| 网络 | dio，装配点 `lib/core/service/dio_provider.dart`（`apiClientProvider`） |
| 路由 | go_router，`lib/core/route/app_route.dart` |
| 本地存储 | shared_preferences，`lib/core/service/preferences_provider.dart` |
| UI 组件库 | **ForUI 0.26**（`package:forui/forui.dart`），图标用其自带 lucide（`Icon(FLucideIcons.xxx)`） |
| 模型 | 手写 `fromJson`（单一解析入口），**不引入 freezed/json_serializable** |
| 后端 | 同仓 `Backend/`（Go，`ehviewer-webd`），HTTP 契约见 `Backend/README.md` |

## 2. 常用命令

```bash
flutter analyze     # 提交前必须 0 issue（info 级也算 issue）
flutter test        # 单测 + widget 测试
flutter run -d macos
```

后端（本仓 `Backend/`）：

```bash
cd Backend
go test ./...                        # 需要 Go 1.27.1；本机 go 在 /usr/local/go/bin
docker compose build && docker compose up -d
```

**注意**：本机 Go 不在 PATH 里，且构建缓存要指向可写目录：

```bash
export PATH=/usr/local/go/bin:$PATH GOCACHE=/tmp/ehw-gocache GOTMPDIR=/tmp
```

## 3. 目录映射（本项目历史命名 ↔ 全局规范）

本项目 feature 用的目录名与全局规范的 `data` / `application` / `presentation` 一一对应：

| 全局规范概念 | 本项目实际目录 |
| --- | --- |
| `data/` | `<feature>/datasource/`（子目录 `local` / `remote` / `runtime`） |
| `data/model/` | `<feature>/model/`（子目录 `dto` `request` `response` `vo` `bo` `table` `state`） |
| `application/repository/` | `<feature>/repository/` |
| `application/service/` | `<feature>/service/` |
| `presentation/` | `<feature>/ui/` |
| `presentation/viewmodel/` | `<feature>/ui/provider/`（Riverpod provider 即 viewmodel） |
| `presentation/view/` | `<feature>/ui/view/` |
| `presentation/widget/` | `<feature>/ui/widget/` |

现有模块：`auth`、`library`、`main`、`reader`、`setting`。

规则：**禁止**为了对齐命名批量重命名/移动既有目录；新文件跟随所属 feature 现有兄弟文件的目录与命名。

## 4. 本项目特有约定

- **UI 组件一律 ForUI**：`FScaffold` / `FHeader` / `FButton` / `FCard` / `FTile` / `FTextFormField` / `FSwitch` / `FSelect` / `FPopover` / `FCircularProgress` / `FDivider` / `FBadge`；弹窗 `showFDialog` + `FDialog.adaptive`；底部面板 `showFSheet`；toast `showFToast`。
  **禁止** Material 的 `Scaffold` / `AppBar` / `NavigationBar` / `ElevatedButton` / `TextButton` / `IconButton` / `ListTile` / `AlertDialog` / `TextField` / `CircularProgressIndicator` / `FilterChip` / `Slider` / `Switch`。
- **主题 token 走 `context.theme`**：`colors` / `typography`（`typography.body.{xs,sm,md,lg,xl}`）/ `style.pagePadding` / `style.borderRadius` / `style.sizes`。
  间距、圆角、图标尺寸用 `lib/common/config/app_config.dart` 的 `AppSpacing` / `AppRadius` / `AppIcon`；禁止就地写 `8` / `12` / `16` 这类裸数字，禁止硬编码色值。
- **`MaterialApp.router` 例外，且必须来自 `material_ui`**：Flutter 3.44 起 Material 已从 SDK 独立成 `package:material_ui`，forui 0.26 也建立在它之上，而 `package:flutter/material.dart` 是**另一套实现**——两者的 `ThemeData` 互不相容，混用是类型错误。
  所以 `lib/main.dart` 用 `material_ui` 的 `MaterialApp.router` + `toApproximateMaterialTheme()`（主题单一来源），`FTheme` / `FToaster` / `FTooltipGroup` 注入在 `builder` 里。**不要**改成 `package:flutter/material.dart` 的 `MaterialApp`，也不要改成纯 forui 启动器（forui 不提供路由宿主）。
  参考项目 TeleBook 用的是 forui **0.24.3**（那时还 import `flutter/material`），那套写法在本项目**无法编译**，不要照抄。
- **品牌色只允许**在 `lib/main.dart` 的 `_brandTheme` 里集中定义。
- **通用组件放 `lib/common/widget/`**：`CustomErrorWidget`（带 `onRetry`）、`CustomEmptyWidget`、`FSheetContent`（**面板背景由它画**，forui 的 `FSheet` 只负责定位/动画/拖拽）、`ServerImage`、`FDialogContent`（`FDialog` 不管内容边距，由 builder 提供）、`showServerAddressDialog`。优先复用，不要重写。
- **服务器地址的编辑弹窗在 `common/widget/server_address_dialog.dart`**，**两个入口共用**：设置页，以及**登录页**。后者不是可选功能——未登录时路由把设置页挡在外面，默认地址不对就彻底卡死，登录页上那个「修改」是唯一的自救出口。保存与「地址变了就清本地会话」这条不变式在 `core/service/server_address.dart`，不在任何 feature 里。
- **`FHeaderAction` 只能住在 `FHeader` 里**：它断言必须能从 `FHeaderData` 取样式与尺寸，放进普通 `Row`（例如自建工具条）会**先触发断言，再因为缺少 header 约束撑出巨量横向溢出**（实测 19 万像素）。自建工具条/控制条用 `FButton(variant: FButtonVariant.ghost)` 或 `FTappable`。
  forui 里要求在特定祖先下的组件还有：`FSelectGroupItemMixin`（需 `FSelectGroup`）、`FBottomNavigationBarItem`（需 `FBottomNavigationBar`）、`FPaginationItem`、`FSelectTile`、`FAccordion`、`FBreadcrumbItem`、`FResizable`、`FAutocomplete` 系列、`FOtpField`、`FPicker`。新增用法前先确认祖先存在。
- **跨 feature 只走 service**：例如 reader 需要画廊详情时依赖 `library_service`，不 import library 的 repository/datasource/ui。provider 之间不互相 import，需要共享就下沉到 service。
- **`Result<T>` 的 Dart 变体**：全局规范里 `Result` 同时有 `error` 字段和 `static Result.error()`，Dart 不允许同名，因此本项目用**命名构造器**实现同样的调用形式（`Result.error(e)` / `Result.success(v)`），字段与 getter 不变。见 `lib/core/util/result_util.dart`。
- **`GlobalException` 是 `sealed`**：新增业务异常类型需要改 `lib/core/exception/global_exception.dart`（外部库无法继承 sealed 类）。
- 平台目录（`android/` `ios/` `web/` `macos/` `linux/` `windows/`）不在 lint 范围内，非必要不改。
  **例外**：
  - `macos/Runner/*.entitlements` 必须保留 `com.apple.security.network.client`，否则 macOS 沙箱会拒绝一切外发连接（包括 127.0.0.1），且报错表现为「无法连接」而不是权限问题。
  - `ios/Runner/Info.plist` 必须保留 `NSLocalNetworkUsageDescription`：iOS 14+ 真机连**局域网地址**（192.168.x.x）要用户授权，没有这个说明字符串系统不会弹框、连接直接失败。回环与公网隧道不需要它。
  - iOS **不需要** ATS 例外（`NSAllowsArbitraryLoads` / `NSAllowsLocalNetworking`）：Flutter 那条「默认禁用不安全 HTTP」的策略只作用于平台原生 socket，官方文档明确写了 socket 归 Dart/Flutter 所有时不施加策略；本项目用 dio 的默认 dart:io 适配器。别照抄网上加 `NSAllowsArbitraryLoads` 的教程。
  - **模拟器**用 `http://127.0.0.1:8080` 连宿主机后端（模拟器共享 Mac 的网络栈，回环即 Mac 回环）；**真机**才有局域网地址、权限与端口发布的问题。

## 5. 已知存量差距（新代码不得效仿，改到哪收敛到哪）

| 位置 | 现状 | 目标 |
| --- | --- | --- |
| `lib/feature/setting/ui/view/setting_view.dart` | 598 行，私有子组件（`_InfoTile`/`_SectionTitle`/`_PrefCard`/两个弹窗）都留在同一文件 | 需要时把弹窗与卡片拆到 `ui/widget/`；视图不像 service 那样有硬阈值，暂未动 |
| `ApiClient.streamEvents` 的非 2xx 分支 | 流响应的 `response.data` 是 `ResponseBody`，读不到 `error.code/message`，只剩通用状态码文案 | 需要精确错误码时再解流体的开头几帧 |
| 后端快照 | `data/` 目录需要手机上手动「导出数据」才有 | 属后端设计，不是前端问题；前端不得假设快照存在 |
