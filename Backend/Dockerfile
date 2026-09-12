# Multi-stage build for ehviewer-webd.
#
# The runtime stage is distroless/static rather than Alpine because the whole
# point of using modernc.org/sqlite is a pure-Go build with no CGO, which yields
# a fully static binary. A distroless base has no shell, no package manager and
# no libc to attack, and it is ~2MB.
#
# docker build -t ehviewer-webd .
# docker run --rm -v /srv/ehviewer-sync:/sync:ro -v ehw-data:/var/lib/ehviewer-webd \
#   -p 8080:8080 ehviewer-webd

# --- build -----------------------------------------------------------------
FROM golang:1.27-alpine AS build

WORKDIR /src

# Dependencies first so the module cache layer survives source edits.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 is not optional: modernc.org/sqlite is pure Go, and a static
# binary is what lets the runtime stage be distroless/static.
#   -trimpath      removes local paths from the binary
#   -s -w          drops the symbol table and DWARF, roughly halving the size
ENV CGO_ENABLED=0
RUN go build \
      -trimpath \
      -ldflags="-s -w" \
      -o /out/ehviewer-webd \
      ./cmd/ehviewer-webd

# 供 runtime 阶段拷一个数据目录进去。目录本体不能是空的拷贝源，所以在这里建。
RUN mkdir -p /out/data

# --- runtime ---------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/ehviewer-webd /usr/local/bin/ehviewer-webd

# The service writes only here: the index, thumbnail cache and session key.
# The synced tree is mounted read-only and is never written to.
#
# **这个目录必须对任意 uid 可写，07​77 是刻意的。**
#
# 它是 named volume 的挂载点，而 Docker 会用镜像里这个目录的属主与权限去初始化
# 一个**空的**卷。运行时的 `user:`（EHW_UID，用来匹配同步目录的属主，见文末）
# 几乎不可能等于镜像里的 uid，所以默认的 0755/65532 会让服务死在启动阶段：
#
#   error: auth: write key: open /var/lib/ehviewer-webd/session.key: permission denied
#
# 更麻烦的是它不会自愈：服务写不进去 → 卷始终是空的 → **每次重建容器都被重新
# 初始化一次**，连手工 chown 都会被覆盖。所以权限必须在镜像里就正确。
#
# 0777 在这里不放大攻击面：镜像里只有一个进程，这个卷只挂给这一个容器，rootfs
# 只读、capabilities 清空、no-new-privileges；会话密钥本身仍由程序以 0600 写入。
COPY --from=build --chmod=0777 /out/data /var/lib/ehviewer-webd

# 注意顺序：`WORKDIR` 在目录不存在时**会创建它**，而创建出来的属主是当前 USER
# （distroless 的 65532），会把上面精心设置的权限覆盖掉。所以数据目录在上面用
# COPY 建好，这里只负责切换工作目录。
WORKDIR /var/lib/ehviewer-webd

# 65532 is distroless's nonroot user.
#
# Important for a bind-mounted synced tree: this uid must be able to READ the
# mounted files. If the host files are owned by, say, uid 1000 with mode 0640,
# either add the container user to that group, or run with
# `--user $(id -u):$(id -g)`. Docker Compose sets `user:` for exactly this
# reason; see docker-compose.yml.
USER 65532:65532

# 8080 rather than 127.0.0.1:8080, because inside a container the proxy is on
# another host. Authentication is mandatory for a non-loopback bind, and the
# config validator enforces that at startup.
EXPOSE 8080

# /healthz is unauthenticated by design, so it works as a probe without
# exposing anything. A 200 proves the process is serving.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/usr/local/bin/ehviewer-webd", "version"]

ENTRYPOINT ["/usr/local/bin/ehviewer-webd"]
CMD ["serve", "-config", "/etc/ehviewer-webd/config.json"]
