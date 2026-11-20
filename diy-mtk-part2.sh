#!/bin/bash
# Redmi AX6S 自定义配置：在 Feeds 安装之后、make defconfig 之前执行。
# 保留 Rust、Boost、FRP、Firewall4 的既有兼容方案。
# NaiveProxy、Xray 与 Sing-box 改用官方正式版 ARM64 预编译文件；保持 OpenWrt 软件包及服务集成。
set -Eeuo pipefail
trap 'echo "[diy-part2] 第 ${LINENO} 行执行失败，请检查上方日志" >&2' ERR

# 一、修改默认 LAN 地址。
sed -i 's#192.168.1.1#192.168.0.1#g' package/base-files/files/bin/config_generate

# 二、保留既有 Rust 兼容方案。
echo '[diy-part2] 准备 Rust 兼容软件包...'
if [ ! -d packages/lang/rust ]; then
  git clone --depth=1 https://github.com/coolsnowwolf/packages.git packages
fi
test -d packages/lang/rust
rm -rf feeds/packages/lang/rust
cp -a packages/lang/rust feeds/packages/lang/rust
rm -rf packages

# 三、Boost 兼容性检查。
echo '[diy-part2] Boost 使用 ImmortalWrt 上游原生配置，跳过旧版兼容补丁。'

# 四、FRP：编译时自动选择 GitHub 上最新的正式版源码（排除带后缀的预发布 tag）。
# 保留 ImmortalWrt 原有 frpc/frps 软件包、UCI 配置和 init 服务，跳过 Web UI 的 Node 构建。
echo '[diy-part2] 查询 FRP 最新稳定版本...'
FRP_DIR='feeds/packages/net/frp'
FRP_MAKEFILE="$FRP_DIR/Makefile"
test -f "$FRP_MAKEFILE"

grep -q '^PKG_VERSION:=' "$FRP_MAKEFILE"
grep -q '^PKG_HASH:=' "$FRP_MAKEFILE"
grep -q '^GO_PKG_BUILD_PKG:=' "$FRP_MAKEFILE"
grep -q '^define Build/Compile$' "$FRP_MAKEFILE"
grep -q 'codeload.github.com/fatedier/frp' "$FRP_MAKEFILE" || {
  echo '[diy-part2] FRP 源码下载源不再是预期的 GitHub codeload，拒绝替换 HASH' >&2
  exit 1
}

FRP_VERSION="$(
  git ls-remote --tags --refs https://github.com/fatedier/frp.git \
    | sed -nE 's#^[0-9a-f]+[[:space:]]+refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' \
    | sort -V \
    | tail -n 1
)"
if [[ ! "$FRP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo '[diy-part2] 无法确定 FRP 最新稳定版，停止编译，避免静默回退旧版' >&2
  exit 1
fi

FRP_ARCHIVE="$(mktemp /tmp/frp-source.XXXXXXXX.tar.gz)"
curl --fail --location --retry 3 --connect-timeout 20 --max-time 180 \
  "https://codeload.github.com/fatedier/frp/tar.gz/v${FRP_VERSION}" \
  --output "$FRP_ARCHIVE"

# 校验压缩包可被读取，再计算与 OpenWrt PKG_SOURCE_URL 对应的源码 SHA256。
tar -tzf "$FRP_ARCHIVE" >/dev/null
FRP_HASH="$(sha256sum "$FRP_ARCHIVE" | awk '{print $1}')"
rm -f "$FRP_ARCHIVE"
[[ "$FRP_HASH" =~ ^[0-9a-f]{64}$ ]] || {
  echo '[diy-part2] FRP 源码 SHA256 无效' >&2
  exit 1
}

cp "$FRP_MAKEFILE" "${FRP_MAKEFILE}.bak"
sed -i -E "s/^PKG_VERSION:=.*/PKG_VERSION:=${FRP_VERSION}/" "$FRP_MAKEFILE"
sed -i -E "s/^PKG_HASH:=.*/PKG_HASH:=${FRP_HASH}/" "$FRP_MAKEFILE"
# noweb 不需要 node/host；但仍需要满足该 FRP 版本要求的 Go 编译器。
sed -i -E 's#^(PKG_BUILD_DEPENDS:=)golang/host[[:space:]]+node/host#\1golang/host#' "$FRP_MAKEFILE"
if grep -q '^GO_PKG_TAGS:=' "$FRP_MAKEFILE"; then
  sed -i -E 's/^GO_PKG_TAGS:=.*/GO_PKG_TAGS:=noweb/' "$FRP_MAKEFILE"
else
  sed -i '/^GO_PKG_BUILD_PKG:=/a GO_PKG_TAGS:=noweb' "$FRP_MAKEFILE"
fi

# 替换旧配方中的 npm/Web 构建，只运行 Go 编译，并在上游结构变化时拒绝错误替换。
python3 - <<'PY_FRP_COMPILE'
from pathlib import Path
import re
p = Path('feeds/packages/net/frp/Makefile')
s = p.read_text()
new = 'define Build/Compile\n\t$(call GoPackage/Build/Compile)\nendef'
s, count = re.subn(r'^define Build/Compile\n.*?^endef$', lambda _: new,
                   s, flags=re.M | re.S)
if count != 1:
    raise SystemExit('[diy-part2] FRP Build/Compile 结构发生变化，拒绝覆盖')
p.write_text(s)
PY_FRP_COMPILE

rm -rf build_dir/target-*/frp-*
echo "[diy-part2] FRP 已选择 v${FRP_VERSION}，源码 SHA256=${FRP_HASH}（noweb 源码编译）"

# 五、适配 ImmortalWrt 新版 Firewall4 的 FullCone NAT 默认配置补丁。
echo '[diy-part2] 适配 Firewall4 FullCone NAT 补丁...'
python3 - <<'PY'
from pathlib import Path
p = Path('package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch')
if not p.is_file():
    raise SystemExit('[diy-part2] 找不到 FullCone NAT 补丁')
s = p.read_text()
head = '--- a/root/etc/config/firewall\n'
next_file = '--- a/root/usr/share/firewall4/templates/ruleset.uc\n'
a = s.find(head)
b = s.find(next_file, a + len(head))
if a < 0 or b < 0:
    raise SystemExit('[diy-part2] FullCone 补丁格式不符合预期')
old = s[a:b]
if not all(k in old for k in ('option flow_offloading', 'option flow_offloading_hw',
                                'option fullcone', 'option fullcone6')):
    raise SystemExit('[diy-part2] FullCone 补丁内容发生变化，拒绝覆盖')
new = (
    '--- a/root/etc/config/firewall\n'
    '+++ b/root/etc/config/firewall\n'
    '@@ -1,8 +1,12 @@\n'
    ' config defaults\n'
    ' \toption syn_flood\t1\n'
    ' \toption input\t\tREJECT\n'
    ' \toption output\t\tACCEPT\n'
    ' \toption forward\t\tREJECT\n'
    '+\toption flow_offloading\t1\n'
    '+\toption flow_offloading_hw\t1\n'
    '+\toption fullcone\t\t1\n'
    '+\toption fullcone6\t0\n'
    ' \n'
    ' config zone\n'
    ' \toption name\t\tlan\n'
)
if old != new:
    p.write_text(s[:a] + new + s[b:])
print('[diy-part2] FullCone 第一段补丁已适配')
PY

# 六、官方二进制构建：只接受正式版、校验 Release SHA256、AArch64 与静态链接。
# 注意 Sing-box 必须选择 linux-arm64-musl；普通 arm64 版需要附带 libcronet.so。
echo '[diy-part2] 获取 NaiveProxy、Xray 和 Sing-box 官方预编译文件...'
python3 - <<'PY'
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
import hashlib
import io
import json
import os
import re
import struct
import tarfile
import time
import zipfile

ROOT = Path.cwd()
AGENT = 'AX6S-OpenWrt-prebuilt/2.0'
TOKEN = os.environ.get('GH_TOKEN', '')

# 下载只允许 HTTPS；查询 API 可以使用工作流令牌以避免匿名限额。
def download(url, api=False):
    if not url.startswith('https://'):
        raise RuntimeError('拒绝非 HTTPS 下载地址')
    headers = {'User-Agent': AGENT, 'Accept': 'application/vnd.github+json' if api else 'application/octet-stream'}
    if api and TOKEN:
        headers['Authorization'] = 'Bearer ' + TOKEN
    for attempt in range(3):
        try:
            with urlopen(Request(url, headers=headers), timeout=90) as response:
                return response.read()
        except (HTTPError, URLError, TimeoutError) as exc:
            if attempt == 2:
                raise RuntimeError(f'下载失败：{url}：{exc}') from exc
            time.sleep(2 * (attempt + 1))

# 最新正式版须有唯一的目标架构资产和 GitHub 发布元数据 SHA256。
def get_release(repo, name_fn):
    meta = json.loads(download(f'https://api.github.com/repos/{repo}/releases/latest', api=True))
    tag = meta.get('tag_name', '')
    if meta.get('draft') or meta.get('prerelease') or not re.fullmatch(r'v[0-9][0-9A-Za-z.\-]*', tag):
        raise RuntimeError(f'{repo} 最新发布状态或标签不符合预期：{tag}')
    asset_name = name_fn(tag)
    assets = [a for a in meta.get('assets', []) if a.get('name') == asset_name]
    if len(assets) != 1:
        raise RuntimeError(f'{repo} 未找到官方资产：{asset_name}')
    asset = assets[0]
    digest = asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise RuntimeError(f'{asset_name} 未提供可核验的官方 SHA256')
    url = asset.get('browser_download_url', '')
    if not url.startswith(f'https://github.com/{repo}/releases/download/{tag}/'):
        raise RuntimeError(f'{asset_name} 下载地址异常')
    print(f'[diy-part2] 下载 {repo} {tag}：{asset_name}', flush=True)
    blob = download(url)
    if hashlib.sha256(blob).hexdigest() != digest[7:]:
        raise RuntimeError(f'{asset_name} SHA256 校验失败')
    return tag[1:], blob, digest

# 只从受信的官方归档内提取唯一的目标文件；不执行归档内脚本。
def from_tar(data, basename, mode='r:xz'):
    with tarfile.open(fileobj=io.BytesIO(data), mode=mode) as tf:
        matches = [m for m in tf.getmembers() if m.isfile() and Path(m.name).name == basename]
        if len(matches) != 1:
            raise RuntimeError(f'官方归档内 {basename} 数量异常：{len(matches)}')
        return tf.extractfile(matches[0]).read()

def from_zip(data, basename):
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        names = [n for n in zf.namelist() if not n.endswith('/') and Path(n).name == basename]
        if len(names) != 1:
            raise RuntimeError(f'官方归档内 {basename} 数量异常：{len(names)}')
        return zf.read(names[0])

# ARM64 小端静态 ELF：禁止 PT_INTERP（动态加载器）。
def check_elf(name, data):
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01':
        raise RuntimeError(f'{name} 不是 64 位小端 ELF 文件')
    if struct.unpack_from('<H', data, 18)[0] != 183:
        raise RuntimeError(f'{name} 不是 AArch64 架构')
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phentsize, phnum = struct.unpack_from('<HH', data, 54)
    if phentsize < 56 or phoff + phentsize * phnum > len(data):
        raise RuntimeError(f'{name} ELF 程序头异常')
    for i in range(phnum):
        header = phoff + phentsize * i
        ptype = struct.unpack_from('<I', data, header)[0]
        if ptype == 3:  # 动态加载器程序头
            raise RuntimeError(f'{name} 存在动态加载器，拒绝将其封装为静态程序')
        if ptype == 2:  # 动态段：进一步检查是否依赖其它共享库。
