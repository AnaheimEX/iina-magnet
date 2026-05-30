#!/usr/bin/env bash
#
# sync-upstream.sh — merge an upstream IINA release into the iina-magnet fork,
# preserving all custom features. See docs/UPSTREAM_SYNC.md for the full guide.
#
#   ./scripts/sync-upstream.sh v1.4.3     # fetch + branch + merge + verify
#   ./scripts/sync-upstream.sh --verify   # just re-run verification (after
#                                         # resolving conflicts on the branch)
#
set -euo pipefail

UPSTREAM_URL="https://github.com/iina/iina.git"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Re-runnable verification: dylibs (upstream may have bumped mpv), the custom
# package's tests, then the whole app build with the required signing flags.
run_verify() {
  say "验证 1/3 · 重新拉取预编译依赖 (mpv/dylib)"
  PROJECT_NAME=iina-magnet bash other/download_libs.sh --skip-plugins

  say "验证 2/3 · 自定义库回归测试"
  ( cd iina-magnet && swift test )

  say "验证 3/3 · 整 app 编译 (ad-hoc 签名)"
  xcodebuild -scheme iina -configuration Debug -derivedDataPath /tmp/iina-dd \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build

  ok "全部验证通过。确认无误后合回 develop:"
  echo "    git checkout develop && git merge --no-ff $(git rev-parse --abbrev-ref HEAD)"
  echo "    git push origin develop"
}

TARGET="${1:-}"
[ -n "$TARGET" ] || die "用法: $0 <upstream-tag>   例如 $0 v1.4.3   (或 $0 --verify)"

if [ "$TARGET" = "--verify" ]; then
  run_verify
  exit 0
fi

# 0. clean working tree
[ -z "$(git status --porcelain)" ] || die "工作区不干净，请先提交或暂存改动。"

# 1. upstream remote + fetch
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
say "拉取上游 tags…"
git fetch upstream --tags

# 2. tag exists?
git rev-parse -q --verify "refs/tags/$TARGET^{commit}" >/dev/null \
  || die "找不到上游 tag: $TARGET （用 'git ls-remote --tags upstream' 查看可用版本）"

# 3. branch off develop
git checkout develop
BRANCH="sync/upstream-$TARGET"
say "新建合并分支 $BRANCH"
git checkout -B "$BRANCH"

# 4. merge the release tag
say "合并 $TARGET …"
if git merge --no-edit "$TARGET"; then
  ok "合并无冲突。"
  run_verify
else
  warn "存在冲突，需手动解决。冲突文件:"
  git diff --name-only --diff-filter=U | sed 's/^/    /'
  cat <<EOF

参考 docs/UPSTREAM_SYNC.md §2 / §5 解决（重点照顾 hook 与 project.pbxproj）。
解决后:
    git add -A && git commit --no-edit
    ./scripts/sync-upstream.sh --verify
EOF
  exit 2
fi
