#!/usr/bin/env sh
# install.sh — 拉取 liteflow.conf、compose YAML、watch.sh，并启动 compose
# Usage:
#   ./install.sh [-y] [<host-name>]
# Examples:
#   ./install.sh -y
#   ./install.sh node-01.example.internal
#
# 非交互模式（跳过询问）：
#   ./install.sh -y
#   ASSUME_YES=1 ./install.sh
#
# 可用环境变量覆盖：
#   CONF_REPO  COMPOSE_REPO  FETCH_URL  WATCH_URL
#   DEST_CONF  MODE  COMPOSE_SRC_PATH  COMPOSE_DEST_FILE

set -eu

# -------- 默认配置（可用 env 覆盖） --------
: "${CONF_REPO:=git@github.com:xnervwang/liteflow-conf-repo.git}"
: "${COMPOSE_REPO:=git@github.com:xnervwang/liteflow-docker-compose-repo.git}"
: "${FETCH_URL:=https://raw.githubusercontent.com/xnervwang/Liteflow/refs/heads/venus/scripts/fetch-conf.sh}"
: "${WATCH_URL:=https://raw.githubusercontent.com/xnervwang/liteflow-docker-compose-installer/refs/heads/main/watch.sh}"

: "${DEST_CONF:=liteflow.conf}"         # 本地保存的 liteflow 配置
: "${MODE:=--force}"                    # --force | --backup
: "${COMPOSE_DEST_FILE:=compose.yaml}"  # 本地保存的 compose 文件名
# ----------------------------------------

usage() {
  echo "Usage: $0 [-y] [<host-name>]"
  echo "Examples:"
  echo "  $0 -y"
  echo "  $0 node-01.example.internal"
  exit 1
}

# 解析 -y
YES=0
[ "${ASSUME_YES:-}" = "1" ] && YES=1
if [ "${1:-}" = "-y" ]; then YES=1; shift; fi

# host 参数可选：缺省则取当前机器 hostname
HOST="${1:-}"
if [ -n "$HOST" ]; then shift; fi
[ -z "${HOST:-}" ] && HOST="$(hostname -f 2>/dev/null || hostname 2>/dev/null || uname -n)"

# 额外参数不应存在
[ $# -gt 0 ] && usage

# 依据 host 推导远端 compose/conf 路径（可用 COMPOSE_SRC_PATH 覆盖）
: "${COMPOSE_SRC_PATH:=${HOST}.yaml}"
CONF_SRC_PATH="output/${HOST}.conf"

# ---------- 依赖检测（只检测不安装） ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' not found."; exit 127; }; }

# 下载器：curl 或 wget 二选一
DOWNLOADER=""
command -v curl >/dev/null 2>&1 && DOWNLOADER="curl"
[ -z "$DOWNLOADER" ] && command -v wget >/dev/null 2>&1 && DOWNLOADER="wget"
[ -n "$DOWNLOADER" ] || { echo "Error: need 'curl' or 'wget'."; exit 127; }

need git
need bash
# docker / compose
if ! command -v docker >/dev/null 2>&1; then echo "Error: 'docker' not found."; exit 127; fi
DCOMPOSE=""
if docker compose version >/dev/null 2>&1; then DCOMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DCOMPOSE="docker-compose"
else
  echo "Error: neither 'docker compose' nor 'docker-compose' found."; exit 127
fi

# SSH 仅在 repo 为 SSH URL 时要求
case "$CONF_REPO $COMPOSE_REPO" in
  *git@*|*ssh://*) need ssh ;;
esac

# 可选工具告警 + 询问
missing=""
command -v jq  >/dev/null 2>&1 || missing="$missing jq"
command -v cmp >/dev/null 2>&1 || missing="$missing cmp"
if [ -n "$missing" ]; then
  echo "Warning: optional tools missing:${missing}"
  echo "  - jq  : 用于 JSON 校验（缺失则跳过校验）
  - cmp : 用于无差异检测（缺失则总是覆盖或备份）"
  if [ "$YES" -ne 1 ]; then
    printf "Continue without these? [y/N]: "
    read ans || ans=""
    case "$ans" in y|Y|yes|YES) : ;; *) echo "Aborted."; exit 2 ;; esac
  fi
fi

# ---------- 通用下载函数 ----------
dl() {
  # dl <url> <dest>
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL --retry 3 --retry-delay 1 "$1" -o "$2"
  else
    # BusyBox wget 兼容：无 --retry 用默认重试策略
    wget -qO "$2" "$1"
  fi
  [ -s "$2" ] || { echo "Error: download failed or empty: $1"; return 1; }
}

# ---------- 下载 fetch-conf.sh ----------
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
FETCH_SH="$TMPDIR/fetch-conf.sh"
echo "[install] downloading fetch-conf.sh: $FETCH_URL"
dl "$FETCH_URL" "$FETCH_SH" || { echo "Error: cannot fetch fetch-conf.sh"; exit 10; }
chmod +x "$FETCH_SH"

# ---------- 拉 liteflow.conf ----------
echo "[install] fetching conf from $CONF_REPO : $CONF_SRC_PATH -> ./$DEST_CONF ($MODE)"
if ! bash "$FETCH_SH" git "$MODE" "$CONF_REPO" "$CONF_SRC_PATH" "./$DEST_CONF"; then
  echo "Error: failed to fetch conf. Check:"
  echo "  - repo access (SSH key/permissions)"
  echo "  - path exists in repo: $CONF_SRC_PATH"
  exit 11
fi
[ -s "./$DEST_CONF" ] || { echo "Error: dest conf is missing or empty: $DEST_CONF"; exit 12; }

# ---------- 拉 compose YAML ----------
echo "[install] fetching compose from $COMPOSE_REPO : $COMPOSE_SRC_PATH -> ./$COMPOSE_DEST_FILE ($MODE)"
if ! bash "$FETCH_SH" git "$MODE" "$COMPOSE_REPO" "$COMPOSE_SRC_PATH" "./$COMPOSE_DEST_FILE"; then
  echo "Error: failed to fetch compose file. Check:"
  echo "  - repo access (SSH key/permissions)"
  echo "  - path exists in repo: $COMPOSE_SRC_PATH"
  exit 13
fi
[ -s "./$COMPOSE_DEST_FILE" ] || { echo "Error: compose file missing or empty: $COMPOSE_DEST_FILE"; exit 14; }

# ---------- 拉 watch.sh（公开 raw） ----------
echo "[install] downloading watch.sh: $WATCH_URL -> ./watch.sh"
dl "$WATCH_URL" ./watch.sh || { echo "Error: cannot fetch watch.sh"; exit 15; }
chmod +x ./watch.sh

###############################################################################
# 新增：从 Git 拉取/更新源码并构建两张镜像
# - xnervwang/ddns-go-docker:main  （源：ddns-go-docker.git @ main）
# - xnervwang/liteflow:venus       （源：Liteflow.git @ venus）
###############################################################################
# 可被环境变量覆盖的默认设置
: "${DDNS_BUILD_REPO:=https://github.com/xnervwang/ddns-go-docker.git}"
: "${DDNS_BUILD_BRANCH:=main}"
: "${DDNS_BUILD_WORKDIR:=/tmp/ddns-go-docker}"
: "${DDNS_BUILD_CONTEXT_SUBDIR:=.}"
: "${DDNS_BUILD_DOCKERFILE:=}"             # 为空则用默认 Dockerfile
: "${DDNS_BUILD_TAG:=xnervwang/ddns-go-docker:main}"

: "${LITEFLOW_BUILD_REPO:=https://github.com/xnervwang/Liteflow.git}"
: "${LITEFLOW_BUILD_BRANCH:=venus}"
: "${LITEFLOW_BUILD_WORKDIR:=/tmp/Liteflow}"
: "${LITEFLOW_BUILD_CONTEXT_SUBDIR:=.}"
: "${LITEFLOW_BUILD_DOCKERFILE:=}"         # 为空则用默认 Dockerfile
: "${LITEFLOW_BUILD_TAG:=xnervwang/liteflow:venus}"

git_sync_reset() {
  # git_sync_reset <repo> <branch> <workdir>
  repo="$1"; branch="$2"; workdir="$3"
  if [ -d "$workdir/.git" ]; then
    echo "[install] updating $workdir -> origin/$branch"
    git -C "$workdir" fetch --all --prune
    git -C "$workdir" checkout "$branch"
    git -C "$workdir" reset --hard "origin/$branch"
  else
    echo "[install] cloning $repo#$branch -> $workdir"
    rm -rf "$workdir"
    git clone --depth 1 --branch "$branch" "$repo" "$workdir"
  fi
}

docker_build_here() {
  # docker_build_here <workdir> <context_subdir> <dockerfile> <tag>
  workdir="$1"; subdir="$2"; dfile="$3"; tag="$4"
  ctx="$workdir"
  [ "$subdir" != "." ] && ctx="$workdir/$subdir"
  echo "[install] building image $tag from $ctx ${dfile:+(Dockerfile=$dfile)}"
  if [ -n "$dfile" ]; then
    docker build --network host -t "$tag" -f "$ctx/$dfile" "$ctx"
  else
    docker build --network host -t "$tag" "$ctx"
  fi
}

# 1) ddns-go-docker -> xnervwang/ddns-go-docker:main
git_sync_reset "$DDNS_BUILD_REPO" "$DDNS_BUILD_BRANCH" "$DDNS_BUILD_WORKDIR"
docker_build_here "$DDNS_BUILD_WORKDIR" "$DDNS_BUILD_CONTEXT_SUBDIR" "$DDNS_BUILD_DOCKERFILE" "$DDNS_BUILD_TAG"

# 2) Liteflow -> xnervwang/liteflow:venus
git_sync_reset "$LITEFLOW_BUILD_REPO" "$LITEFLOW_BUILD_BRANCH" "$LITEFLOW_BUILD_WORKDIR"
docker_build_here "$LITEFLOW_BUILD_WORKDIR" "$LITEFLOW_BUILD_CONTEXT_SUBDIR" "$LITEFLOW_BUILD_DOCKERFILE" "$LITEFLOW_BUILD_TAG"

# ---------- 解析 compose 中的 container_name 并处理冲突 ----------
conflict_names="$(awk '
  $1 ~ /container_name:/ {
    sub(/^[[:space:]]*container_name:[[:space:]]*/, "", $0)
    gsub(/["'\''"]/, "", $0)
    sub(/[[:space:]]+$/, "", $0)
    if (length($0)>0) print $0
  }
' "$COMPOSE_DEST_FILE" | sort -u)"

to_remove=""
if [ -n "$conflict_names" ]; then
  for name in $conflict_names; do
    if docker ps -a --format '{{.Names}}' | grep -Fx "$name" >/dev/null 2>&1; then
      echo "Found existing container with same container_name: $name"
      to_remove="$to_remove $name"
    fi
  done
fi

if [ -n "$to_remove" ]; then
  if [ "$YES" -ne 1 ]; then
    echo "The following containers will be removed to avoid name conflicts:"
    for n in $to_remove; do echo "  - $n"; done
    printf "Proceed to remove them? [y/N]: "
    read ans || ans=""
    case "$ans" in y|Y|yes|YES) : ;; *) echo "Aborted."; exit 16 ;; esac
  fi
  for n in $to_remove; do docker rm -f "$n" >/dev/null 2>&1 || true; done
fi

# ---------- 校验 compose 语法 ----------
echo "[install] validating compose syntax ..."
if ! $DCOMPOSE -f "./$COMPOSE_DEST_FILE" config -q >/dev/null 2>&1; then
  echo "Error: 'docker compose config -q' failed. Compose file may be invalid."
  exit 17
fi

# ---------- 写入 .env（供 compose 使用） ----------
ENV_FILE="./.env"
echo "[install] writing $ENV_FILE for liteflow-conf-puller"
cat > "$ENV_FILE" <<EOF
# Generated by install.sh at $(date -Iseconds)
FETCH_URL=$FETCH_URL
CONF_REPO=$CONF_REPO
CONF_SRC=output/${HOST}.conf
DEST_FILE=/app/etc/${DEST_CONF}
INTERVAL=60
EOF

# ---------- 启动 compose ----------
echo "[install] bringing up services with $COMPOSE_DEST_FILE ..."
if ! $DCOMPOSE --env-file "$ENV_FILE" -f "./$COMPOSE_DEST_FILE" up -d --force-recreate --remove-orphans; then
  echo "Error: compose up failed."
  exit 18
fi

echo "[install] done."
echo "Files:"
echo "  $(pwd)/$DEST_CONF"
echo "  $(pwd)/$COMPOSE_DEST_FILE"
