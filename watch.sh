#!/bin/sh
set -eu
: "${DOCKER_API:?DOCKER_API is required}"
: "${TARGET:?TARGET is required}"
: "${FILE:?FILE is required}"

DIR=$(dirname "$FILE")
BASE=$(basename "$FILE")

echo "[watch] watching $FILE for changes ..."
# 监听 close_write / move / create，以兼容原子替换写法
inotifywait -m -e close_write,move,create "$DIR" | while read -r d ev name; do
  [ "$name" = "$BASE" ] || continue
  # 防抖，合并瞬间的多次事件
  sleep 0.3
  echo "[watch] $FILE changed ($ev) -> sending SIGUSR1 to $TARGET"
  # 调 Docker API 只执行 kill 操作
  if curl -fsS -X POST "$DOCKER_API/containers/$TARGET/kill?signal=SIGUSR1" >/dev/null; then
    echo "[watch] signal sent."
  else
    echo "[watch] failed to signal $TARGET" >&2
  fi
done
