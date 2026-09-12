# EhviewerOnline

把一台机器上 **Syncthing 同步过来的 EhViewer 图库**变成一个只读的在线库：一个 Go
服务端负责索引与出图，一个 Flutter 客户端负责浏览与阅读。

```
Syncthing ──► <同步目录>/EhViewer
                    │ 只读
                    ▼
          Backend/  (ehviewer-webd)  ──HTTP──►  Frontend/  (Flutter)
          索引 · 缩略图 · 会话                 macOS / iOS / Android / Web
```

两半各自有更详细的文档，**先读它们**：

| 目录 | 是什么 | 文档 |
| --- | --- | --- |
| `Backend/` | Go 服务端。走目录树、解析 `.ehviewer`、只读导出的 SQLite 快照，索引后通过 HTTP 提供浏览与读图 | [`Backend/README.md`](Backend/README.md)（含**完整 HTTP 契约**） |
| `Frontend/` | Flutter 客户端。同一个代码库跑 macOS / iOS / Android / Web | [`Frontend/AGENTS.md`](Frontend/AGENTS.md)（目录映射、forui 约定、平台注意事项） |

## 快速开始

### 1. 服务端

```sh
cd Backend

# 生成访问令牌（deploy/token 已被 .gitignore 忽略，不要提交）
mkdir -p deploy
openssl rand -base64 32 > deploy/token
chmod 600 deploy/token

# EHW_SYNC_DIR 指向同步目录本身（里面应有 download/ 与 data/），
# EHW_UID/EHW_GID 必须等于该目录的属主，否则容器读不到文件。
EHW_SYNC_DIR=/path/to/EhViewer \
EHW_UID=$(id -u) EHW_GID=$(id -g) \
docker compose up -d
```

服务默认发布在 `127.0.0.1:8080`（**只监听回环**，由同机的 frp 客户端转发出去，
不直接暴露给局域网）。详见 `Backend/README.md` 的安全章节。

### 2. 客户端

```sh
cd Frontend
flutter run -d macos      # 或 -d ios / -d android / -d chrome
```

服务器地址有编译期默认值，也可以在**登录页或设置页直接改**并持久化：

```sh
flutter run -d macos --dart-define=EHW_BASE_URL=https://your-host
```

> 模拟器连本机服务端用 `http://127.0.0.1:8080` 即可（模拟器与宿主共享网络栈）。
> 真机连局域网地址还需要后端把端口发布到局域网，并授予 iOS 本地网络权限——
> 见 `Frontend/AGENTS.md` 的平台注意事项。

## 测试

```sh
cd Backend  && go test ./...
cd Frontend && flutter analyze && flutter test
```

## 几个容易踩的点

- **图库元数据不是自动同步的。** 导出的 SQLite 快照需要有人在手机上手动
  「设置 → 高级 → 导出数据」落到同步目录的 `data/`。没有它，服务端仍然能用
  **目录名**解析出标题、作者、汉化组、系列、展会、属性这些筛选维度（见
  `Backend/README.md` 的 *Derived tags*），但分类、评分、书签、官方标签没有。
- **同步目录始终只读挂载**（`:ro`）。这不是装饰：它是内核级的保证，服务端不可能
  写进 Syncthing 管理的目录。
- **`deploy/token` 与 `.env` 已被忽略**。不要在别处贴出令牌；一旦误提交，除了
  洗历史还要**换令牌**。

## 目录

```
.
├── Backend/     Go 服务端（Docker + distroless 镜像）
└── Frontend/    Flutter 客户端（common / core / feature 三层结构）
```
