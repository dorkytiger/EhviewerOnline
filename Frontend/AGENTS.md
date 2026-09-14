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
| 本地文件 | path_provider 2.1.6，只在**有 dart:io 的平台**编译进去（`lib/core/service/file_store.dart` 条件导入），用于缩略图缓存与离线下载 |
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

现有模块：`auth`、`download`、`library`、`main`、`reader`、`setting`。

规则：**禁止**为了对齐命名批量重命名/移动既有目录；新文件跟随所属 feature 现有兄弟文件的目录与命名。

## 3.1 跨模块依赖图（现状）

```
auth ←── core ──► (server_address / session / prefs / file_store / thumbnail_cache)
library ──► core
download ──► core, library（service：取详情）
reader   ──► library（service：取详情）, download（service：取页字节 / 离线重建详情）
```

- `download` 取图**不经过 library**：它自己用 `core` 的 `ApiClient` 拼地址、取字节
  （`DownloadRemoteDatasource`），所以这条边不会和 `library → …` 形成环。
- `library` 的详情页只有一个「下载」按钮，**导航到** `/gallery/:gid/download` 就完事，
  不 import download 的任何东西——下载的状态全归 download 自己管。
- 阅读器是唯一同时依赖两个 feature 的模块：线上路径要 `library` 的详情，本地路径要
  `download` 的页字节与离线详情。它自己不碰文件系统，也不拼图片 URL。
- 唯一新增的 `common/widget` 是 `confirm_dialog.dart`（退出登录、删除下载、清空缓存
  共用），别再写第三份二次确认弹窗。

## 4. 本项目特有约定

- **UI 组件一律 ForUI**：`FScaffold` / `FHeader` / `FButton` / `FCard` / `FTile` / `FTextFormField` / `FSwitch` / `FSelect` / `FPopover` / `FCircularProgress` / `FDivider` / `FBadge`；弹窗 `showFDialog` + `FDialog.adaptive`；底部面板 `showFSheet`；toast `showFToast`。
  **禁止** Material 的 `Scaffold` / `AppBar` / `NavigationBar` / `ElevatedButton` / `TextButton` / `IconButton` / `ListTile` / `AlertDialog` / `TextField` / `CircularProgressIndicator` / `FilterChip` / `Slider` / `Switch`。
- **主题 token 走 `context.theme`**：`colors` / `typography`（`typography.body.{xs,sm,md,lg,xl}`）/ `style.pagePadding` / `style.borderRadius` / `style.sizes`。
  间距、圆角、图标尺寸用 `lib/common/config/app_config.dart` 的 `AppSpacing` / `AppRadius` / `AppIcon`；禁止就地写 `8` / `12` / `16` 这类裸数字，禁止硬编码色值。
- **`MaterialApp.router` 例外，且必须来自 `material_ui`**：Flutter 3.44 起 Material 已从 SDK 独立成 `package:material_ui`，forui 0.26 也建立在它之上，而 `package:flutter/material.dart` 是**另一套实现**——两者的 `ThemeData` 互不相容，混用是类型错误。
  所以 `lib/main.dart` 用 `material_ui` 的 `MaterialApp.router` + `toApproximateMaterialTheme()`（主题单一来源），`FTheme` / `FToaster` / `FTooltipGroup` 注入在 `builder` 里。**不要**改成 `package:flutter/material.dart` 的 `MaterialApp`，也不要改成纯 forui 启动器（forui 不提供路由宿主）。
  参考项目 TeleBook 用的是 forui **0.24.3**（那时还 import `flutter/material`），那套写法在本项目**无法编译**，不要照抄。
- **品牌色只允许**在 `lib/common/config/app_theme.dart` 的 `_brandTheme` 里集中定义（`buildBrandThemes()`，`main.dart` 只是调用方）。主题测试在 `test/app_theme_test.dart`；widget 测试的夹具请用 `buildBrandThemes(touch: true).$1`，**不要**再各造一套 `FTheme.neutral.light.touch`——主题里改了什么，自造的那套永远测不到（childPadding 那次就是这么漏出去的）。
- **`FScaffold` 默认会给内容左右各加 12 px，已经在品牌主题里归零**（`scaffoldStyle.childPadding = EdgeInsets.zero`）。所以：
  - **不要**再写 `childPad: false`，也不需要写 `childPad: true`；
  - 每个页面自己控制留白（列表用 `theme.style.pagePadding`，详情页用 `AppSpacing.xl`）；
  - 回归测试 `test/app_theme_test.dart` 量了「内容左边缘 = 0」，`test/gallery_detail_layout_test.dart` 量了详情页的精确偏移（窄屏 24、宽屏 308）——加回来就会红。
- **所有 `showFDialog` 的内容都必须走 `FDialogContent`**：forui 的 `FDialog` 只管定位/动画/遮罩，**内容边距是每个 builder 自己的事**——忘了就顶到弹窗边框上（`confirmDialog` 曾经就是这样，三个入口全中）。新增弹窗时照抄 `common/widget/{confirm_dialog,server_address_dialog}.dart` 的写法，不要再自己排一份 Column。
- **通用组件放 `lib/common/widget/`**：`CustomErrorWidget`（带 `onRetry`）、`CustomEmptyWidget`、`confirmDialog`（危险操作二次确认，契约测试在 `test/confirm_dialog_test.dart`）、`FSheetContent`（**面板背景由它画**，forui 的 `FSheet` 只负责定位/动画/拖拽）、`ServerImage`、`FDialogContent`（`FDialog` 不管内容边距，由 builder 提供）、`showServerAddressDialog`。优先复用，不要重写。
- **服务器地址的编辑弹窗在 `common/widget/server_address_dialog.dart`**，**两个入口共用**：设置页，以及**登录页**。后者不是可选功能——未登录时路由把设置页挡在外面，默认地址不对就彻底卡死，登录页上那个「修改」是唯一的自救出口。保存与「地址变了就清本地会话」这条不变式在 `core/service/server_address.dart`，不在任何 feature 里。
- **`FHeaderAction` 只能住在 `FHeader` 里**：它断言必须能从 `FHeaderData` 取样式与尺寸，放进普通 `Row`（例如自建工具条）会**先触发断言，再因为缺少 header 约束撑出巨量横向溢出**（实测 19 万像素）。自建工具条/控制条用 `FButton(variant: FButtonVariant.ghost)` 或 `FTappable`。
  forui 里要求在特定祖先下的组件还有：`FSelectGroupItemMixin`（需 `FSelectGroup`）、`FBottomNavigationBarItem`（需 `FBottomNavigationBar`）、`FPaginationItem`、`FSelectTile`、`FAccordion`、`FBreadcrumbItem`、`FResizable`、`FAutocomplete` 系列、`FOtpField`、`FPicker`。新增用法前先确认祖先存在。
- **跨 feature 只走 service**：例如 reader 需要画廊详情时依赖 `library_service`，不 import library 的 repository/datasource/ui。provider 之间不互相 import，需要共享就下沉到 service。
- **文件系统一律走 `core/service/file_store.dart`**，不要直接 import `dart:io`：Web 构建里不能出现 `dart:io`，所以它与 `path_provider` 只出现在 `file_store_io.dart`（条件导入的 io 分支）里。`FileStore` 的所有方法都不抛异常，失败以返回值表达（false / null / 空表）。
  - `cacheDirectory()` 放**可被系统回收**的东西：封面缩略图缓存（`thumbnail_cache.dart`，设置页「存储」区块有开关、占用、清除；Web 退化为纯内存）。
  - `supportDirectory()` 放**用户主动下载**的东西：离线下载，系统不会自动清理它。
  - 缓存键不要用 `String.hashCode`（跨进程不稳定），也不要用 64 位 FNV 常量（dart2js 编译不过，见 `thumbnail_cache.dart` 里的注释）。
- **下载模块（`feature/download/`）**：唯一事实来源是 `<support>/downloads/<gid>/manifest.json`，不另存 SharedPreferences 索引。管理页是底部导航第三个目的地（图库 / 下载 / 设置）。
  - 页文件按**位置**命名（`0007.jpg`），原始文件名与 mtime 记在清单里用于**身份校验**；位置对不上当前详情就回源，绝不拿旧文件顶上（服务端重扫后同位置就是另一张图）。
  - 清单在开始下载时就写（`partial`），已存在且身份一致的页跳过 → **断点续传**；取消与失败都保留现场。
  - `reader` 取页字节走 `DownloadService.pageBytes`：本机有且身份一致就用本机，否则回源。**本地优先只有这一处实现**，所以阅读器里不再有「空 URL 提前拒绝」这类判断。
  - **断网可读**：服务器不可达时 `ReaderService.detail` 退到 `DownloadService.localDetail`（用清单重建页列表，元数据填 `unknown`），所以下载过的整本可以离线继续读；「下载」页的卡片直接进阅读器，不经过需要服务器的详情页。图库浏览与**发起下载**仍然需要服务器。
  - Web 上 `FileStore.supported == false`，下载入口显示「此平台不支持本地下载」，不要用 IndexedDB / Cache API 假装支持。
  - 下载以 `gid` 为键、不区分服务器地址：换服务器后同一 gid 可能是另一本画廊，这由身份校验兜住（对不上就回源），管理列表显示的仍是下载时的标题。
- **`Result<T>` 的 Dart 变体**：全局规范里 `Result` 同时有 `error` 字段和 `static Result.error()`，Dart 不允许同名，因此本项目用**命名构造器**实现同样的调用形式（`Result.error(e)` / `Result.success(v)`），字段与 getter 不变。见 `lib/core/util/result_util.dart`。
- **`GlobalException` 是 `sealed`**：新增业务异常类型需要改 `lib/core/exception/global_exception.dart`（外部库无法继承 sealed 类）。
- 平台目录（`android/` `ios/` `web/` `macos/` `linux/` `windows/`）不在 lint 范围内，非必要不改。
  **例外**：
  - `macos/Runner/*.entitlements` 必须保留 `com.apple.security.network.client`，否则 macOS 沙箱会拒绝一切外发连接（包括 127.0.0.1），且报错表现为「无法连接」而不是权限问题。
  - `ios/Runner/Info.plist` 必须保留 `NSLocalNetworkUsageDescription`：iOS 14+ 真机连**局域网地址**（192.168.x.x）要用户授权，没有这个说明字符串系统不会弹框、连接直接失败。回环与公网隧道不需要它。
  - iOS **不需要** ATS 例外（`NSAllowsArbitraryLoads` / `NSAllowsLocalNetworking`）：Flutter 那条「默认禁用不安全 HTTP」的策略只作用于平台原生 socket，官方文档明确写了 socket 归 Dart/Flutter 所有时不施加策略；本项目用 dio 的默认 dart:io 适配器。别照抄网上加 `NSAllowsArbitraryLoads` 的教程。
  - **模拟器**用 `http://127.0.0.1:8080` 连宿主机后端（模拟器共享 Mac 的网络栈，回环即 Mac 回环）；**真机**才有局域网地址、权限与端口发布的问题。
- **应用图标：设计在代码里，铺图交给 `flutter_launcher_icons`**。
  - 图形定义在 `test/tools/app_icon_art.dart`（概念、调色板、各平台的圆角/留白/安全区规则），源图由 `test/tools/render_app_icon.dart` 用 `dart:ui` 画出来落到 `assets/icon/`：`app_icon.png`（满幅不透明，iOS/Android 旧图标/web/Windows）、`app_icon_foreground.png`（Android 自适应前景，图形已缩进 66/108 安全圆）、`app_icon_macos.png`（留白 + 圆角 + 投影，macOS 系统不裁图标）。
  - 改图标的完整流程：改 `app_icon_art.dart` → `flutter test test/tools/render_app_icon.dart` → `dart run flutter_launcher_icons`（配置 `flutter_launcher_icons.yaml`）。两个工具文件都**故意不以 `_test.dart` 结尾**，`flutter test` 不会顺手跑它们；预览输出 `test/tools/out/` 已忽略，源图 `assets/icon/` 要提交。
  - `adaptive_icon_foreground_inset` 必须是 **0**：前景图自己已经留好安全区，包里默认的 16 会再缩一圈，图形会明显偏小。
  - ⚠️ **每次跑完 `flutter_launcher_icons` 都要看一眼 `git diff ios/Runner.xcodeproj/project.pbxproj`**：0.14.4 会把 `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` 的值从 `YES` 改成 `AppIcon`（那个键只接受布尔，纯属误改；实测不会让构建失败，但必须改回来）。它也会把 iOS 的 `Contents.json` 压成一行，那是它自己的格式，别手工排版。
  - 还没做的：Android 13 的 monochrome 主题图标（`adaptive_icon_monochrome`）需要单独的**剪影**设计——把现在的图形染成白色会丢掉叠卡的层次，所以不是加个 target 就完事；iOS 18 的深色/着色变体同理。
- **详情 / 下载 / 阅读器三条路由在 shell 之外，进入它们一律用 `push`，不要用 `go`**：`go` 会把整个栈换成「只有这一页」，下面什么都没有——Android 的侧边滑动返回（系统返回手势）于是把应用**退到桌面**，iOS 的滑动返回也一起失效。`go` 只留给真正的「换掉当前位置」：登录成功回图库、兜底页回首页、阅读器 `_back()` 在没有上一页时回详情。
  - 这三条路由必须**平级**（`/gallery/:gid`、`/gallery/:gid/read`、`/gallery/:gid/download`），不能把后两条写成 `:gid` 的子路由：`push` 一个子路由时 go_router 会把父路由页面一起压栈，从阅读器返回会先回到一个一模一样的详情页（看起来像「返回没反应」）。
  - 回归测试在 `test/navigation_stack_test.dart`：它既查路由表（push 之后 `canPop()` 必须为真、pop 一次回到上一层），也**走真实的调用点**（点画廊磁贴、点下载页卡片），因为 `go`/`push` 的差别只有调用点知道。
  - 那个测试还要关掉 Riverpod 的自动重试（`ProviderContainer(retry: (_, __) => null)`）并给 `fileStoreProvider` 塞内存实现：桩服务端的详情请求会失败，自动重试会留下定时器让 `pumpAndSettle` 报 pending timer。
- **窄屏布局：详情页只有一个断点（720）**。≥720 是海报式并排（封面 260 + 右栏标题与事实，见 `_Header`）；<720 分两段——封面 + 标题一行，事实（胶囊标签、键值对）**整宽**排在下面。
  - 封面宽度**按可用宽度算**（`_coverWidthFor`，比例 0.30、夹在 88–130），不要写死 130：320 宽的手机上定值加间距会吃掉一半屏宽，标题列只剩 118 px，`_KeyValue` 的值只剩 40 px，整块看起来像坏了（真机截图报过这个 bug，回归测试在 `test/gallery_detail_layout_test.dart`）。
  - 同排的标题用 `body.xl`（22 px）而不是 `body.xl2`（30 px）：`xl2` 的行高倍数是 2.25，一行占 67 px，窄列里一行只放得下四个字。
  - 同类问题：单行 `Wrap` 里的胶囊如果比整行还宽，会变成 RenderFlex 溢出（Wrap 只在胶囊**之间**换行），所以 `_Pill` 的文字要 `Flexible` + 省略号。
- **widget 测试里不能碰真实的 `path_provider`**：平台通道的回复要靠事件循环驱动，而
  `testWidgets` 跑在假时钟里，一旦在构建路径上 `await` 平台通道就会永远挂住，表现为
  `pumpAndSettle timed out`。需要文件的测试用 `test/support/memory_file_store.dart` 里的
  `MemoryFileStore` 覆盖 `fileStoreProvider`。

## 5. 已知存量差距（新代码不得效仿，改到哪收敛到哪）

| 位置 | 现状 | 目标 |
| --- | --- | --- |
| `download` 的清单读取 | 阅读器每取一页都读一次 `manifest.json`（几十 KB 的 JSON 解析） | 若实测成为瓶颈，再在 runtime 层加一份带失效的清单缓存；缓存失效写错会读到错的一页，所以现在宁可多读一次 |
| `download` 的下载任务 | 同一时刻只允许一个下载任务（第二个请求被明确拒绝） | 需要并行下载时，`DownloadTaskRuntime` 里的单个 `CancelToken` 要改成按 gid 分组的任务表 |
| `lib/feature/setting/ui/view/setting_view.dart` | 571 行，私有子组件（`_InfoTile`/`_SectionTitle`/`_PrefCard`/`_ImageCacheCard`/服务器信息区块）都留在同一文件 | 需要时把弹窗与卡片拆到 `ui/widget/`；视图不像 service 那样有硬阈值，暂未动 |
| `ApiClient.streamEvents` 的非 2xx 分支 | 流响应的 `response.data` 是 `ResponseBody`，读不到 `error.code/message`，只剩通用状态码文案 | 需要精确错误码时再解流体的开头几帧 |
| 后端快照 | `data/` 目录需要手机上手动「导出数据」才有 | 属后端设计，不是前端问题；前端不得假设快照存在 |
