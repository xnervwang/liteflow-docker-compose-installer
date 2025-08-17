#!/bin/sh
set -eu
: "${DOCKER_API:?DOCKER_API is required}"
: "${TARGET:?TARGET is required}"
: "${FILE:?FILE is required}"

DIR=$(dirname "$FILE")
BASE=$(basename "$FILE")

# 为什么要“监听父目录 + 按文件名过滤”，而不是直接监听单个文件？
# 1) 很多编辑器/同步器/脚本更新配置时走“原子替换”：先写临时文件，再 rename 到目标名。
#    这会导致目标文件的 inode 发生变化；如果你对“旧 inode”设置了 inotify 监视，rename 后
#    这个监视点就失效，从而漏掉这次更新。
# 2) 监听父目录能捕获到 rename 落位（moved_to）和首次创建（create）事件，再结合文件名过滤，
#    既能覆盖原子替换，又能覆盖就地写入（close_write），更可靠。
#
# 监控的事件说明：
# - close_write：对同一 inode 的就地写入并关闭（echo >>、覆盖写等）
# - moved_to   ：有文件被重命名/移动为目标名（原子替换的典型落位动作）
# - create     ：首次创建目标文件

echo "[watch] watching $FILE (via parent dir $DIR) ..."
inotifywait -m -e close_write,create,moved_to --format '%e %w%f' "$DIR" \
| while read -r ev path; do
  # 只响应我们关心的那个文件
  [ "$path" = "$FILE" ] || continue

  # 轻微防抖，合并瞬时多次事件（编辑器写临时文件、rename 可能触发多次）
  sleep 0.3

  echo "[watch] $ev -> sending SIGUSR1 to $TARGET"
  if curl -fsS -X POST "$DOCKER_API/containers/$TARGET/kill?signal=SIGUSR1" >/dev/null; then
    echo "[watch] signal sent."
  else
    echo "[watch] failed to signal $TARGET" >&2
  fi
done
