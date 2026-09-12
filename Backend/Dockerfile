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

# --- runtime ---------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/ehviewer-webd /usr/local/bin/ehviewer-webd

# The service writes only here: the index, thumbnail cache and session key.
# The synced tree is mounted read-only and is never written to.
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
