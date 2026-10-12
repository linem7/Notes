#!/usr/bin/env bash
# 在本机构建 Notes 并安装到 /Applications（见 README 的「从源码构建和安装」）。
# 用法：在仓库里运行 ./scripts/install.sh
set -euo pipefail

fail() {
    echo "✗ $*" >&2
    exit 1
}

step() {
    echo "==> $*"
}

# 在仓库根目录执行，后面的相对路径都以它为准
cd "$(dirname "$0")/.." || fail "进不了仓库根目录。"

step "检查环境"
[[ "$(uname)" == "Darwin" ]] || fail "只能在 macOS 上运行。"
command -v xcodebuild >/dev/null || fail "找不到 xcodebuild：请安装 Xcode 26，然后运行 sudo xcode-select -s /Applications/Xcode.app"
command -v xcodegen >/dev/null || fail "找不到 xcodegen：请先运行 brew install xcodegen"
# 先把输出存下来再查：直接接 grep -q 的话，grep 提前退出会让 security 收到 SIGPIPE，在 pipefail 下误报失败
identities="$(security find-identity -v -p codesigning)" || fail "读取 Keychain 里的签名证书失败。"
grep -q '"Notes Self-Signed"' <<<"$identities" \
    || fail "Keychain 里没有能用来签名的证书 Notes Self-Signed：按 README「创建自签名证书」做一次。"

step "生成工程"
xcodegen generate --quiet || fail "xcodegen generate 失败，看上面的输出。"

step "构建 Release（第一次要下载依赖，会慢一些）"
xcodebuild -project Notes.xcodeproj -scheme Notes -configuration Release -derivedDataPath build -quiet build \
    || fail "构建失败，往上翻看 xcodebuild 的错误。签名相关的错误，先检查证书的 Code Signing 是否设成了 Always Trust。"
[[ -d build/Build/Products/Release/Notes.app ]] \
    || fail "构建完成了，但找不到 build/Build/Products/Release/Notes.app。"

step "退出正在运行的 Notes"
# 不能用 pgrep -x Notes：系统自带的备忘录 app 进程也叫 Notes。按安装路径里的可执行文件匹配
is_running() {
    pgrep -f '^/Applications/Notes\.app/Contents/MacOS/Notes$' >/dev/null
}
if is_running; then
    # 第一次运行时 macOS 可能会询问是否允许终端控制 Notes；拒绝的话下面会提示手动退出
    osascript -e 'tell application id "com.linem7.Notes" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        is_running || break
        sleep 0.5
    done
    if is_running; then
        fail "Notes 还在运行：请从菜单栏退出后再运行这个脚本。"
    fi
fi

step "安装到 /Applications"
# 先删掉旧版本：直接覆盖的话，旧 bundle 里多出来的文件会留下，签名会失效
rm -rf /Applications/Notes.app || fail "删除旧版本 /Applications/Notes.app 失败。"
ditto build/Build/Products/Release/Notes.app /Applications/Notes.app \
    || fail "复制到 /Applications 失败。"

step "检查签名"
codesign --verify --deep --strict /Applications/Notes.app \
    || fail "签名校验失败：在 Keychain Access 里确认证书 Notes Self-Signed 的 Code Signing 设成了 Always Trust。"

step "启动"
open /Applications/Notes.app || fail "启动失败：试试在 Finder 里打开 /Applications/Notes.app。"
echo "✓ 已安装。Notes 在菜单栏里。"
