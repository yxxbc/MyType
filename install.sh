#!/usr/bin/env bash
# MyType 一键安装 / 升级（macOS 12 以上，Apple 芯片和 Intel）。
#
#   curl -fsSL https://raw.githubusercontent.com/yxxbc/MyType/main/install.sh | bash
#
# 做三件事：
#   1. 从 GitHub Release 下载最新的 MyType-<版本>-macos.pkg
#   2. 按 SHA256SUMS 校验
#   3. 用系统的 installer 只装给当前用户（~/Library/Input Methods，不要管理员密码）；
#      pkg 装完自己会登记输入法、打开、切过去
# 再跑一遍就是升级。安装包没有 Apple 开发者签名，但 curl 下载的文件不带隔离标记，
# 不用到「隐私与安全性」里放行。
#
# 环境变量：
#   MYTYPE_VERSION=v0.5.0   装指定版本（默认最新）
#   MYTYPE_REPO=owner/repo  指定发布仓库（默认 yxxbc/MyType）
#   MYTYPE_BASE_URL=...     指定资产目录，可以是 file:///...（测试用）
set -euo pipefail

REPO=${MYTYPE_REPO:-yxxbc/MyType}

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m出错：\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：bash install.sh [--print-plan | --help]

默认下载、校验并安装最新的 MyType（macOS pkg）。
--print-plan  只显示架构、仓库和包名，不联网、不安装。

环境变量：MYTYPE_VERSION、MYTYPE_REPO、MYTYPE_BASE_URL（测试用）。
EOF
}

fetch() { # <地址> <保存到>
  if command -v curl >/dev/null; then
    curl -fL --retry 3 --progress-bar -o "$2" "$1"
  else
    wget -q --show-progress -O "$2" "$1"
  fi
}

latest_tag() {
  local url
  if command -v curl >/dev/null; then
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
  else
    url=$(wget -q --max-redirect=5 -S --spider "https://github.com/$REPO/releases/latest" 2>&1 |
          sed -n 's/^ *[Ll]ocation: *//p' | tail -1)
  fi
  url=${url%$'\r'}
  [[ "$url" == */tag/* ]] || die "查不到最新版本（GitHub 连不上？）。可以到 https://github.com/$REPO/releases 手动下载"
  echo "${url##*/tag/}"
}

# 从 SHA256SUMS 里取某个文件的校验和（格式：<hash>  <文件名>）
manifest_hash() { # <文件名> <SHA256SUMS>
  local wanted=$1 manifest=$2 hash filename found= count=0
  while read -r hash filename || [[ -n "$hash" ]]; do
    filename=${filename#\*}
    [[ "$filename" == "$wanted" ]] || continue
    [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    found=$hash
    ((count += 1))
  done < "$manifest"
  [[ $count -eq 1 ]] || return 1
  printf '%s' "$found"
}

main() {
  [[ "$(uname -s)" == Darwin ]] || die "这个仓库只维护 macOS 版；需要 Linux 版请用上游 https://github.com/Gloridust/WowType"
  local machine=${MYTYPE_ARCH:-$(uname -m)}
  case "$machine" in
    arm64|aarch64|x86_64) ;;
    *) die "只支持 Apple 芯片（arm64）和 Intel（x86_64），这台是 $machine" ;;
  esac

  if [[ "${1:-}" == "--print-plan" ]]; then
    local requested=${MYTYPE_VERSION:-<版本>}
    printf '系统：macOS %s\n仓库：%s\n包文件：MyType-%s-macos.pkg\n' "$machine" "$REPO" "${requested#v}"
    return
  fi

  command -v curl >/dev/null || die "需要 curl"
  local tag version package base expected actual tmp
  tag=${MYTYPE_VERSION:-$(latest_tag)}
  [[ "$tag" == v* ]] || tag="v$tag"
  version=${tag#v}
  [[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+~^-]*$ ]] || die "无效的版本号：$version"
  base=${MYTYPE_BASE_URL:-"https://github.com/$REPO/releases/download/$tag"}
  package="MyType-$version-macos.pkg"
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' EXIT

  say "MyType ${version}（macOS $machine）"
  fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" 2>/dev/null ||
    die "下载 $base/SHA256SUMS 失败，请检查版本和网络；发布页：https://github.com/$REPO/releases"
  expected=$(manifest_hash "$package" "$tmp/SHA256SUMS") ||
    die "MyType $version 没有 macOS 安装包（${package}）；发布页：https://github.com/$REPO/releases"
  say "下载并校验 $package"
  fetch "$base/$package" "$tmp/$package"
  actual=$(shasum -a 256 "$tmp/$package")
  [[ "${actual%% *}" == "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" ]] || die "$package 校验和对不上，请重新下载"

  say "安装到 ~/Library/Input Methods（只装给当前用户）"
  installer -pkg "$tmp/$package" -target CurrentUserHomeDirectory
  say "装好了，已经登记并打开 MyType。"
  echo "菜单栏的输入法里选 MyType 就能用。"
  echo "没看到的话：系统设置 → 键盘 → 文字输入 → 输入法 → 编辑 → ＋ → 简体中文 → MyType；"
  echo "还没有就注销重新登录一次。"
}

case "${1:-}" in
  -h|--help) usage ;;
  --print-plan) main --print-plan ;;
  "") main ;;
  *) usage; exit 2 ;;
esac
