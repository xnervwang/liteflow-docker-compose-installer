#!/usr/bin/env sh
# install.sh — 获取 docker-compose.yml 与 env.template，生成 .env，并以指定 project 启动
# 支持来源：
#   1) 直链 HTTP(S) 文件（public 或带认证头）
#   2) Git 仓库单文件（SSH/HTTPS）：格式 repo.git#branch:path/to/file （用 sparse-checkout）
#
# 必填输入（命令行或环境变量）：
#   COMPOSE_PROJECT_NAME   HOSTNAME   PUBLIC_IPV4_DOMAIN   PRIVATE_IPV4_DOMAIN
#
# 必填来源（命令行或环境变量）：
#   COMPOSE_SRC   ENV_TMPL_SRC
#     - 直链示例：https://example.com/path/docker-compose.yml
#     - Git 单文件示例（SSH）：git@github.com:owner/repo.git#main:deploy/docker-compose.yml
#     - Git 单文件示例（HTTPS）：https://github.com/owner/repo.git#main:deploy/env.template
#
# 可选认证输入：
#   TOKEN         —— 用于 HTTPS（Git 或 API/直链）：作为 Bearer 放入 Authorization 头
#   AUTH_HEADER   —— 自定义完整 Authorization 头；存在时优先于 TOKEN
#   SSH_KEY       —— 指定 SSH 私钥路径，用于 SSH URL（默认用当前用户 key/agent）
#
# 运行示例（推荐把 project 也传给 -p）：
#   COMPOSE_PROJECT_NAME=node35 \
#   HOSTNAME=node35.raspberrypi.xnerv.wang \
#   PUBLIC_IPV4_DOMAIN=node35.raspberrypi.xnerv.wang \
#   PRIVATE_IPV4_DOMAIN=internal.node35.raspberrypi.xnerv.wang \
#   COMPOSE_SRC="git@github.com:owner/repo.git#main:deploy/docker-compose.yml" \
#   ENV_TMPL_SRC="https://api.github.com/repos/owner/private-repo/contents/env.template?ref=main" \
#   TOKEN=github_pat_xxx \
#   ./install.sh -y
#
# 最终会在当前目录生成/覆盖：
#   ./docker-compose.yml
#   ./.env

set -eu

YES=0
[ "${ASSUME_YES:-}" = "1" ] && YES=1

# ------------ 参数解析 ------------
usage() {
  cat <<'EOF'
Usage:
  [env vars] ./install.sh [-y]
Required env vars (or pass as inline VAR=... before the command):
  COMPOSE_PROJECT_NAME   Project name for docker compose (-p will also use this)
  HOSTNAME               e.g. node35.raspberrypi.xnerv.wang
  PUBLIC_IPV4_DOMAIN     e.g. node35.raspberrypi.xnerv.wang
  PRIVATE_IPV4_DOMAIN    e.g. internal.node35.raspberrypi.xnerv.wang
  COMPOSE_SRC            Source of docker-compose.yml (URL or git single-file)
  ENV_TMPL_SRC           Source of env.template (URL or git single-file)
Optional:
  TOKEN                  Bearer token for private HTTPS
  AUTH_HEADER            Full Authorization header (overrides TOKEN)
  SSH_KEY                SSH private key for SSH git URLs
  COMPOSE_DEST           Local filename for compose (default: docker-compose.yml)
  ENV_TEMPLATE_DEST      Local filename for template (default: env.template)
  ENV_FILE               Local .env path (default: .env)

  # stunnel: 
  #   - 当 profile 含 'stunnel-mtls' 时：必须提供以下三者
  #     STUNNEL_CAFILE_SRC / STUNNEL_CERT_SRC / STUNNEL_KEY_SRC
  #   - 当 profile 含 'stunnel-https' 时：必须提供以下两者
  #     STUNNEL_CERT_SRC / STUNNEL_KEY_SRC

  STUNNEL_CAFILE_SRC     Source of CA file (URL or git single-file)
  STUNNEL_CERT_SRC       Source of cert (URL or git single-file)
  STUNNEL_KEY_SRC        Source of private key (URL or git single-file)

  # 目标文件名（可选）：若未设置，将自动使用来源 URL/单文件规格的原始文件名
  STUNNEL_CAFILE_DEST    Local filename for CA
  STUNNEL_CERT_DEST      Local filename for cert
  STUNNEL_KEY_DEST       Local filename for key

Flags:
  -y                     non-interactive (assume yes on overwrite, etc.)
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y) YES=1; shift ;;
    *) usage ;;
  esac
done

# ------------ 必填变量校验 ------------
req() { eval "[ -n \"\${$1:-}\" ]" || { echo "Error: missing $1"; exit 2; }; }

# [ddns-go] 仅在启用 ddns-go profile 时校验域名
REQ_DDNS=0
_ddns_profiles=",$(printf '%s' "${COMPOSE_PROFILES:-}" | tr -d ' '),"
case "$_ddns_profiles" in
  *,ddns-go,*) REQ_DDNS=1 ;;
esac

req COMPOSE_PROJECT_NAME
req HOSTNAME
[ "${REQ_DDNS:-0}" -eq 1 ] && req PUBLIC_IPV4_DOMAIN
[ "${REQ_DDNS:-0}" -eq 1 ] && req PRIVATE_IPV4_DOMAIN
req COMPOSE_SRC
req ENV_TMPL_SRC

COMPOSE_DEST="${COMPOSE_DEST:-docker-compose.yml}"
ENV_TEMPLATE_DEST="${ENV_TEMPLATE_DEST:-env.template}"
ENV_FILE="${ENV_FILE:-.env}"

# ------------ 依赖检测 ------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' not found"; exit 127; }; }
need awk
need sed
need mktemp
if ! command -v docker >/dev/null 2>&1; then echo "Error: 'docker' not found"; exit 127; fi
if docker compose version >/dev/null 2>&1; then DCOMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DCOMPOSE="docker-compose"
else
  echo "Error: neither 'docker compose' nor 'docker-compose' found"; exit 127
fi
# git 仅在需要 sparse-checkout 时才必须
need_git_once=1

# ------------ 小工具 ------------
redact_url() {
  # 把 URL 内可能出现的 user:pass@ 段打码
  # 例：https://user:token@host/path -> https://***:***@host/path
  printf '%s' "$1" | awk '
    BEGIN{FS="://"; OFS="://"}
    NF<2{print $0; next}
    {
      proto=$1; rest=$2
      split(rest, a, "@")
      if (length(a)>1 && index(a[1], ":")>0) {
        split(a[1], up, ":"); up[1]="***"; up[2]="***"
        a[1]=up[1] ":" up[2]
        for(i=2;i<=length(a);i++){ a[1]=a[1] "@" a[i] }
        print proto, a[1]
      } else {
        print $0
      }
    }'
}

curl_fetch() {
  # curl_fetch <SRC_URL> <DEST>
  need curl
  src="$1"; dest="$2"
  hdr=""
  if [ -n "${AUTH_HEADER:-}" ]; then
    hdr="$AUTH_HEADER"
  elif [ -n "${TOKEN:-${GITHUB_TOKEN:-}}" ] ; then
    hdr="Authorization: Bearer ${TOKEN:-${GITHUB_TOKEN}}"
  fi
  echo "[fetch] http(s): $(redact_url "$src") -> $dest"
  if [ -n "$hdr" ]; then
    curl -fsSL -H "$hdr" -H "Accept: application/vnd.github.v3.raw" -o "$dest" "$src"
  else
    curl -fsSL -o "$dest" "$src"
  fi
  [ -s "$dest" ] || { echo "Error: empty download: $dest"; exit 10; }
}

git_sparse_fetch() {
  # git_sparse_fetch <GIT_URL#BRANCH:PATH> <DEST>
  need git
  need_git_once=0
  spec="$1"; dest="$2"
  case "$spec" in
    *\#*:* ) : ;;
    *) echo "Error: git single-file spec must be 'repo.git#branch:path'"; exit 11 ;;
  esac
  repo="${spec%%#*}"
  rest="${spec#*#}"
  branch="${rest%%:*}"
  path="${rest#*:}"
  [ -n "$repo" ] && [ -n "$branch" ] && [ -n "$path" ] || { echo "Error: bad spec: $spec"; exit 12; }

  echo "[fetch] git sparse: ${repo} (branch=$branch, path=$path) -> $dest"

  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  GIT_TERMINAL_PROMPT=0 git -C "$tmp" init -q -b main >/dev/null

  # SSH 私钥
  ssh_cmd=""
  case "$repo" in
    git@*|ssh://* )
      if [ -n "${SSH_KEY:-}" ]; then
        ssh_cmd="ssh -i \"$SSH_KEY\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
      else
        ssh_cmd="ssh -o StrictHostKeyChecking=accept-new"
      fi
      ;;
  esac

  # 添加远程
  if [ -n "$ssh_cmd" ]; then
    GIT_SSH_COMMAND="$ssh_cmd" git -C "$tmp" remote add origin "$repo"
  else
    git -C "$tmp" remote add origin "$repo"
  fi

  git -C "$tmp" config core.sparseCheckout true
  mkdir -p "$tmp/.git/info"
  printf '%s\n' "$path" > "$tmp/.git/info/sparse-checkout"

  # HTTPS 私库：用 token 走额外 header
  if [ -z "$ssh_cmd" ] && [ "${repo#https://}" != "$repo" ]; then
    if [ -n "${AUTH_HEADER:-}" ]; then
      git -C "$tmp" -c http.extraHeader="$AUTH_HEADER" fetch --depth 1 origin "$branch" >/dev/null
    elif [ -n "${TOKEN:-${GITHUB_TOKEN:-}}" ]; then
      git -C "$tmp" -c http.extraHeader="Authorization: Bearer ${TOKEN:-${GITHUB_TOKEN}}" fetch --depth 1 origin "$branch" >/dev/null
    else
      git -C "$tmp" fetch -q --depth 1 origin "$branch" >/dev/null 2>&1 || {
        echo "Error: https git needs TOKEN or AUTH_HEADER for private repo"
        exit 13
      }
    fi
  else
    if [ -n "$ssh_cmd" ]; then
      GIT_SSH_COMMAND="$ssh_cmd" git -C "$tmp" fetch --depth 1 origin "$branch" >/dev/null
    else
      git -C "$tmp" fetch -q --depth 1 origin "$branch" >/dev/null
    fi
  fi

  git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD >/dev/null
  [ -s "$tmp/$path" ] || { echo "Error: path not found in repo: $path"; exit 14; }
  mkdir -p "$(dirname "$dest")"
  cp -f "$tmp/$path" "$dest"
}

fetch_any() {
  # fetch_any <SRC> <DEST>
  src="$1"; dest="$2"
  case "$src" in
    http://*|https://*)
      curl_fetch "$src" "$dest"
      ;;
    git@*|ssh://*|*.git\#*:*|https://*.git\#*:*|http://*.git\#*:*|https://github.com/*/*.git\#*:* )
      git_sparse_fetch "$src" "$dest"
      ;;
    *)
      echo "Error: unsupported source: $src"
      exit 15
      ;;
  esac
}

infer_basename_from_src() {
  # infer_basename_from_src <SRC>
  # 支持：
  #   - http(s)://.../path/to/file.ext[?query][#frag]
  #   - repo.git#branch:path/to/file.ext
  src="$1"
  case "$src" in
    http://*|https://*)
      nofrag="${src%%#*}"
      noquery="${nofrag%%\?*}"
      trimmed="${noquery%/}"
      echo "${trimmed##*/}"
      ;;
    *\#*:*|*.git\#*:*|git@*|ssh://*)
      case "$src" in
        *\#*:* )
          path_part="${src#*#}"
          path_part="${path_part#*:}"
          ;;
        *)
          path_part="$src"
          ;;
      esac
      echo "${path_part##*/}"
      ;;
    *)
      echo ""
      ;;
  esac
}

set_kv() {
  # set_kv KEY VALUE FILE   —— 就地覆盖/追加，不做展开
  key="$1"; val="$2"; file="$3"
  awk -v k="$key" -v v="$val" -F= '
    BEGIN{done=0}
    $1==k {print k"="v; done=1; next}
    {print}
    END{if(!done) print k"="v}
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# ------------ 覆盖提示 ------------
maybe_overwrite() {
  f="$1"
  [ -e "$f" ] || return 0
  [ "$YES" -eq 1 ] && return 0
  printf "[install] %s exists; overwrite? [y/N]: " "$f"
  read ans || ans=""
  case "$ans" in y|Y|yes|YES) : ;; *) echo "Aborted."; exit 3 ;; esac
}

# ------------ 下载 compose 与 env.template ------------
maybe_overwrite "$COMPOSE_DEST"
fetch_any "$COMPOSE_SRC" "$COMPOSE_DEST"

maybe_overwrite "$ENV_TEMPLATE_DEST"
fetch_any "$ENV_TMPL_SRC" "$ENV_TEMPLATE_DEST"

[ -s "$COMPOSE_DEST" ] || { echo "Error: empty compose file: $COMPOSE_DEST"; exit 20; }
[ -s "$ENV_TEMPLATE_DEST" ] || { echo "Error: empty env template: $ENV_TEMPLATE_DEST"; exit 21; }

# ------------ 按 profiles 处理 stunnel 三件套下载 ------------
_profiles_normalized=",$(printf '%s' "${COMPOSE_PROFILES:-}" | tr -d ' '),"

# 新逻辑：精确检测 stunnel-mtls / stunnel-https
HAS_STUNNEL_MTLS=0
HAS_STUNNEL_HTTPS=0
case "$_profiles_normalized" in
  *,stunnel-mtls,*) HAS_STUNNEL_MTLS=1 ;;
esac
case "$_profiles_normalized" in
  *,stunnel-https,*) HAS_STUNNEL_HTTPS=1 ;;
esac

verify_pem() {
  # verify_pem <type> <file>
  t="$1"; f="$2"
  case "$t" in
    ca|cert)
      grep -q -- "-----BEGIN CERTIFICATE-----" "$f" || {
        echo "Error: $f does not look like a certificate (missing BEGIN CERTIFICATE)"; exit 24;
      }
      ;;
    key)
      grep -Eq -- "-----BEGIN (ENCRYPTED )?([A-Z0-9 ]+ )?PRIVATE KEY-----" "$f" || {
        echo "Error: $f does not look like a private key (missing BEGIN *PRIVATE KEY)"; exit 25;
      }
      ;;
  esac
}

# 仅在需要时下载，并记录需要校验的目标文件
REQ_FILES=""

if [ "$HAS_STUNNEL_MTLS" -eq 1 ]; then
  # stunnel-mtls：必须有 CA/CERT/KEY
  if [ -z "${STUNNEL_CAFILE_SRC:-}" ] || [ -z "${STUNNEL_CERT_SRC:-}" ] || [ -z "${STUNNEL_KEY_SRC:-}" ]; then
    echo "Error: 'stunnel-mtls' profile detected, but STUNNEL_CAFILE_SRC / STUNNEL_CERT_SRC / STUNNEL_KEY_SRC are not all set"
    exit 22
  fi

  ca_dest="./${STUNNEL_CAFILE_DEST:-$(infer_basename_from_src "$STUNNEL_CAFILE_SRC")}"
  cert_dest="./${STUNNEL_CERT_DEST:-$(infer_basename_from_src "$STUNNEL_CERT_SRC")}"
  key_dest="./${STUNNEL_KEY_DEST:-$(infer_basename_from_src "$STUNNEL_KEY_SRC")}"

  [ -n "${ca_dest##*/}" ]   || { echo "Error: cannot infer CA filename from STUNNEL_CAFILE_SRC"; exit 26; }
  [ -n "${cert_dest##*/}" ] || { echo "Error: cannot infer cert filename from STUNNEL_CERT_SRC"; exit 26; }
  [ -n "${key_dest##*/}" ]  || { echo "Error: cannot infer key filename from STUNNEL_KEY_SRC"; exit 26; }

  maybe_overwrite "$ca_dest"
  fetch_any "$STUNNEL_CAFILE_SRC" "$ca_dest"
  [ -s "$ca_dest" ] || { echo "Error: empty CA file downloaded: $ca_dest"; exit 23; }
  verify_pem ca "$ca_dest"
  echo "[install] stunnel CA -> $ca_dest"

  maybe_overwrite "$cert_dest"
  fetch_any "$STUNNEL_CERT_SRC" "$cert_dest"
  [ -s "$cert_dest" ] || { echo "Error: empty cert file downloaded: $cert_dest"; exit 23; }
  verify_pem cert "$cert_dest"
  echo "[install] stunnel cert -> $cert_dest"

  maybe_overwrite "$key_dest"
  fetch_any "$STUNNEL_KEY_SRC" "$key_dest"
  [ -s "$key_dest" ] || { echo "Error: empty key file downloaded: $key_dest"; exit 23; }
  verify_pem key "$key_dest"
  chmod 600 "$key_dest" 2>/dev/null || true
  echo "[install] stunnel key -> $key_dest"

  REQ_FILES="$REQ_FILES $ca_dest $cert_dest $key_dest"

elif [ "$HAS_STUNNEL_HTTPS" -eq 1 ]; then
  # stunnel-https：只需要 CERT/KEY
  if [ -z "${STUNNEL_CERT_SRC:-}" ] || [ -z "${STUNNEL_KEY_SRC:-}" ]; then
    echo "Error: 'stunnel-https' profile detected, but STUNNEL_CERT_SRC / STUNNEL_KEY_SRC are not set"
    exit 22
  fi

  cert_dest="./${STUNNEL_CERT_DEST:-$(infer_basename_from_src "$STUNNEL_CERT_SRC")}"
  key_dest="./${STUNNEL_KEY_DEST:-$(infer_basename_from_src "$STUNNEL_KEY_SRC")}"

  [ -n "${cert_dest##*/}" ] || { echo "Error: cannot infer cert filename from STUNNEL_CERT_SRC"; exit 26; }
  [ -n "${key_dest##*/}" ]  || { echo "Error: cannot infer key filename from STUNNEL_KEY_SRC"; exit 26; }

  maybe_overwrite "$cert_dest"
  fetch_any "$STUNNEL_CERT_SRC" "$cert_dest"
  [ -s "$cert_dest" ] || { echo "Error: empty cert file downloaded: $cert_dest"; exit 23; }
  verify_pem cert "$cert_dest"
  echo "[install] stunnel cert -> $cert_dest"

  maybe_overwrite "$key_dest"
  fetch_any "$STUNNEL_KEY_SRC" "$key_dest"
  [ -s "$key_dest" ] || { echo "Error: empty key file downloaded: $key_dest"; exit 23; }
  verify_pem key "$key_dest"
  chmod 600 "$key_dest" 2>/dev/null || true
  echo "[install] stunnel key -> $key_dest"

  REQ_FILES="$REQ_FILES $cert_dest $key_dest"

else
  # 未启用 stunnel-mtls / stunnel-https，但设置了来源时，仅告警
  if [ -n "${STUNNEL_CAFILE_SRC:-}" ] || [ -n "${STUNNEL_CERT_SRC:-}" ] || [ -n "${STUNNEL_KEY_SRC:-}" ]; then
    echo "[install][warn] no 'stunnel-mtls' or 'stunnel-https' profile detected, but STUNNEL_*_SRC is set; skip downloading."
  fi
fi

# ------------ 生成 .env ------------
maybe_overwrite "$ENV_FILE"
cp -f "$ENV_TEMPLATE_DEST" "$ENV_FILE"

# 写入关键变量（其余保留模板原值）
set_kv COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME" "$ENV_FILE"
set_kv HOSTNAME "$HOSTNAME" "$ENV_FILE"
[ -n "${PUBLIC_IPV4_DOMAIN:-}" ]  && set_kv PUBLIC_IPV4_DOMAIN  "${PUBLIC_IPV4_DOMAIN:-}"  "$ENV_FILE"
[ -n "${PRIVATE_IPV4_DOMAIN:-}" ] && set_kv PRIVATE_IPV4_DOMAIN "${PRIVATE_IPV4_DOMAIN:-}" "$ENV_FILE"

echo "[install] .env written -> $ENV_FILE"

# ------------ 校验 compose ------------
echo "[install] validating compose config ..."
COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
HOSTNAME="$HOSTNAME" \
PUBLIC_IPV4_DOMAIN="${PUBLIC_IPV4_DOMAIN:-}" \
PRIVATE_IPV4_DOMAIN="${PRIVATE_IPV4_DOMAIN:-}" \
$DCOMPOSE --env-file "$ENV_FILE" -f "$COMPOSE_DEST" -p "$COMPOSE_PROJECT_NAME" config -q

# ------------ 可选构建 ------------
# NO_IMAGE_CACHE=1 时：强制忽略缓存重新构建（默认 1）
if [ "${NO_IMAGE_CACHE:-1}" -eq 1 ]; then
  echo "[install] building images with --no-cache ..."
  COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
  HOSTNAME="$HOSTNAME" \
  PUBLIC_IPV4_DOMAIN="${PUBLIC_IPV4_DOMAIN:-}" \
  PRIVATE_IPV4_DOMAIN="${PRIVATE_IPV4_DOMAIN:-}" \
  $DCOMPOSE --env-file "$ENV_FILE" -f "$COMPOSE_DEST" -p "$COMPOSE_PROJECT_NAME" build --no-cache
else
  echo "[install] building images ..."
  COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
  HOSTNAME="$HOSTNAME" \
  PUBLIC_IPV4_DOMAIN="${PUBLIC_IPV4_DOMAIN:-}" \
  PRIVATE_IPV4_DOMAIN="${PRIVATE_IPV4_DOMAIN:-}" \
  $DCOMPOSE --env-file "$ENV_FILE" -f "$COMPOSE_DEST" -p "$COMPOSE_PROJECT_NAME" build
fi

# ------------ 校验证书文件是否存在且非空 ------------
# 仅在确实需要（启用 stunnel-mtls/https）时做本地文件校验
if [ -n "${REQ_FILES# }" ]; then
  for f in $REQ_FILES; do
    if [ ! -f "$f" ]; then
      echo "[install][ERR] missing file: $f"
      exit 30
    fi
    if [ ! -s "$f" ]; then
      echo "[install][ERR] empty file: $f"
      exit 31
    fi
  done
fi

# ------------ 启动 ------------
echo "[install] bringing up services ..."
COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
HOSTNAME="$HOSTNAME" \
PUBLIC_IPV4_DOMAIN="${PUBLIC_IPV4_DOMAIN:-}" \
PRIVATE_IPV4_DOMAIN="${PRIVATE_IPV4_DOMAIN:-}" \
$DCOMPOSE --env-file "$ENV_FILE" -f "$COMPOSE_DEST" -p"$COMPOSE_PROJECT_NAME" up -d --force-recreate --remove-orphans
echo "[install] done."

# ------------ 额外提示 ------------
if [ "$need_git_once" -eq 0 ]; then
  : # 使用了 git；无动作，仅占位
fi
