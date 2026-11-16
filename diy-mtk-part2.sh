
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

# 四、保留 FRP 0.68.1 的既有兼容方案，跳过 Web UI 编译。
echo '[diy-part2] 处理 FRP 兼容性...'
FRP_MAKEFILE='feeds/packages/net/frp/Makefile'
test -f "$FRP_MAKEFILE"
cp "$FRP_MAKEFILE" "${FRP_MAKEFILE}.bak"
sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:=0.68.1/' "$FRP_MAKEFILE"
sed -i 's/^PKG_HASH:=.*/PKG_HASH:=44ed7107bf35e4f68dc0e77cd5805102effa5301528b89ee5ab0ab379088edc6/' "$FRP_MAKEFILE"
sed -i 's/^PKG_BUILD_DEPENDS:=golang\/host node\/host/PKG_BUILD_DEPENDS:=golang\/host/' "$FRP_MAKEFILE"
grep -q '^GO_PKG_TAGS:=noweb' "$FRP_MAKEFILE" || \
  sed -i '/^GO_PKG_BUILD_PKG:=github.com\/fatedier\/frp\/cmd\/\.\.\./a GO_PKG_TAGS:=noweb' "$FRP_MAKEFILE"
python3 - <<'PY'
from pathlib import Path
import re
p = Path('feeds/packages/net/frp/Makefile')
s = p.read_text()
new = 'define Build/Compile\n\t$(call GoPackage/Build/Compile)\nendef'
s, count = re.subn(r'define Build/Compile\n.*?\nendef', lambda m: new, s, count=1, flags=re.S)
if count != 1:
    raise SystemExit('[diy-part2] FRP Build/Compile 结构发生变化')
p.write_text(s)
PY
rm -rf build_dir/target-*/frp-*
rm -f dl/frp-0.68.1.tar.gz

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
            doff = struct.unpack_from('<Q', data, header + 8)[0]
            dsize = struct.unpack_from('<Q', data, header + 32)[0]
            if doff + dsize > len(data):
                raise RuntimeError(f'{name} ELF 动态段越界')
            for offset in range(doff, doff + dsize - 15, 16):
                dtag = struct.unpack_from('<q', data, offset)[0]
                if dtag == 1:  # 共享库依赖项
                    raise RuntimeError(f'{name} 仍需要共享库，拒绝静态封装')
                if dtag == 0:
                    break

naive_version, naive_archive, naive_digest = get_release(
    'klzgrad/naiveproxy', lambda tag: f'naiveproxy-{tag}-openwrt-aarch64_cortex-a53-static.tar.xz'
)
xray_version, xray_archive, xray_digest = get_release(
    'XTLS/Xray-core', lambda tag: 'Xray-linux-arm64-v8a.zip'
)
sing_version, sing_archive, sing_digest = get_release(
    'SagerNet/sing-box', lambda tag: f'sing-box-{tag[1:]}-linux-arm64-musl.tar.gz'
)
naive_bin = from_tar(naive_archive, 'naive')
xray_bin = from_zip(xray_archive, 'xray')
sing_bin = from_tar(sing_archive, 'sing-box', mode='r:gz')
for name, binary in [('NaiveProxy', naive_bin), ('Xray', xray_bin), ('Sing-box', sing_bin)]:
    check_elf(name, binary)

naive_pkg = ROOT / 'feeds/packages/net/naiveproxy'
xray_pkg = ROOT / 'feeds/packages/net/xray-core'
sing_pkg = ROOT / 'feeds/packages/net/sing-box'
for path in (
    naive_pkg / 'files/naiveproxy.init', naive_pkg / 'files/naiveproxy.config',
    xray_pkg / 'files/xray.init', xray_pkg / 'files/xray.conf',
    xray_pkg / 'files/config.json.example',
    sing_pkg / 'files/sing-box.init', sing_pkg / 'files/sing-box.conf',
):
    if not path.is_file():
        raise RuntimeError(f'官方预编译封装所需文件不存在：{path}')

# 保留许可文件，Sing-box 示例配置取同一官方 Release tag 的源码。
naive_license = from_tar(naive_archive, 'LICENSE')
xray_license = from_zip(xray_archive, 'LICENSE')
try:
    sing_license = from_tar(sing_archive, 'LICENSE', mode='r:gz')
except RuntimeError:
    sing_license = download(f'https://raw.githubusercontent.com/SagerNet/sing-box/v{sing_version}/LICENSE')
sing_example = download(f'https://raw.githubusercontent.com/SagerNet/sing-box/v{sing_version}/release/config/config.json')
json.loads(sing_example)  # 预检示例配置是有效 JSON

for pkg, filename, data in (
    (naive_pkg, 'naive', naive_bin), (naive_pkg, 'LICENSE', naive_license),
    (xray_pkg, 'xray', xray_bin), (xray_pkg, 'LICENSE', xray_license),
    (sing_pkg, 'sing-box', sing_bin), (sing_pkg, 'LICENSE', sing_license),
    (sing_pkg, 'config.json', sing_example),
):
    dest = pkg / 'files/ax6s-prebuilt' / filename
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    dest.chmod(0o755 if filename in ('naive', 'xray', 'sing-box') else 0o644)

# NaiveProxy：仅改变软件包构建方式，继续保留原包名、UCI 与 init 服务。
naive_make = r'''include $(TOPDIR)/rules.mk

PKG_NAME:=naiveproxy
PKG_REAL_VERSION:=@VERSION@
PKG_VERSION:=$(subst -,.,$(PKG_REAL_VERSION))
PKG_RELEASE:=1
PKG_LICENSE:=BSD-3-Clause
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Tianling Shen <cnsztl@immortalwrt.org>
PKG_BUILD_DIR:=$(BUILD_DIR)/naiveproxy-$(PKG_REAL_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/naiveproxy
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Make a fortune quietly
  URL:=https://github.com/klzgrad/naiveproxy
  DEPENDS:=@!(arc||armeb||loongarch64||mips||mips64||powerpc||TARGET_gemini) $(ATOMIC64_DEPENDS)
endef

define Package/naiveproxy/description
  NaiveProxy uses Chromium's network stack for HTTPS proxy transport.
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(INSTALL_BIN) $(CURDIR)/files/ax6s-prebuilt/naive $(PKG_BUILD_DIR)/naive
	$(INSTALL_DATA) $(CURDIR)/files/ax6s-prebuilt/LICENSE $(PKG_BUILD_DIR)/LICENSE
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/naiveproxy/conffiles
/etc/config/naiveproxy
endef

define Package/naiveproxy/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/naive $(1)/usr/bin/naive
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_CONF) $(CURDIR)/files/naiveproxy.config $(1)/etc/config/naiveproxy
	$(INSTALL_BIN) $(CURDIR)/files/naiveproxy.init $(1)/etc/init.d/naiveproxy
endef

$(eval $(call BuildPackage,naiveproxy))
'''.replace('@VERSION@', naive_version)

# Xray：保持 xray-core 和 xray-example 的既有包名与服务文件。
xray_make = r'''include $(TOPDIR)/rules.mk

PKG_NAME:=xray-core
PKG_VERSION:=@VERSION@
PKG_RELEASE:=1
PKG_LICENSE:=MPL-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Tianling Shen <cnsztl@immortalwrt.org>
PKG_BUILD_DIR:=$(BUILD_DIR)/xray-core-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/xray/template
  TITLE:=A proxy platform to bypass network restrictions
  SECTION:=net
  CATEGORY:=Network
  URL:=https://xtls.github.io
endef

define Package/xray-core
  $(call Package/xray/template)
  DEPENDS:=+ca-bundle
endef

define Package/xray-example
  $(call Package/xray/template)
  TITLE+= (example configs)
  DEPENDS:=+xray-core
  PKGARCH:=all
endef

define Package/xray/description
  Xray is a multi-protocol network proxy platform.
endef

define Package/xray-core/description
  $(call Package/xray/description)
endef

define Package/xray-example/description
  $(call Package/xray/description)
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(INSTALL_BIN) $(CURDIR)/files/ax6s-prebuilt/xray $(PKG_BUILD_DIR)/xray
	$(INSTALL_DATA) $(CURDIR)/files/ax6s-prebuilt/LICENSE $(PKG_BUILD_DIR)/LICENSE
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/xray-core/conffiles
/etc/xray/
/etc/config/xray
endef

define Package/xray-core/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/xray $(1)/usr/bin/xray
	$(INSTALL_DIR) $(1)/etc/xray
	$(INSTALL_DATA) $(CURDIR)/files/config.json.example $(1)/etc/xray/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/xray.conf $(1)/etc/config/xray
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/xray.init $(1)/etc/init.d/xray
endef

define Package/xray-example/install
	$(INSTALL_DIR) $(1)/etc/xray
	$(INSTALL_DATA) $(CURDIR)/files/vpoint_socks_vmess.json $(1)/etc/xray/
	$(INSTALL_DATA) $(CURDIR)/files/vpoint_vmess_freedom.json $(1)/etc/xray/
endef

$(eval $(call BuildPackage,xray-core))
$(eval $(call BuildPackage,xray-example))
'''.replace('@VERSION@', xray_version)

# Sing-box：完整 ARM64 musl 官方静态程序内含 Naive 出站，不需要编译 libcronet 或 GN。
# 仅封装完整包；当前 AX6S 并未选择 sing-box-tiny。
sing_make = r'''include $(TOPDIR)/rules.mk

PKG_NAME:=sing-box
PKG_VERSION:=@VERSION@
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Tianling Shen <cnsztl@immortalwrt.org>
PKG_BUILD_DIR:=$(BUILD_DIR)/sing-box-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/sing-box
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=The universal proxy platform (official ARM64 musl)
  URL:=https://sing-box.sagernet.org/
  DEPENDS:=+ca-bundle +kmod-inet-diag +kmod-netlink-diag +kmod-tun
  USERID:=sing-box=5566:sing-box=5566
endef

define Package/sing-box/description
  Official ARM64 musl static build with Naive outbound included.
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(INSTALL_BIN) $(CURDIR)/files/ax6s-prebuilt/sing-box $(PKG_BUILD_DIR)/sing-box
	$(INSTALL_DATA) $(CURDIR)/files/ax6s-prebuilt/LICENSE $(PKG_BUILD_DIR)/LICENSE
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/sing-box/conffiles
/etc/config/sing-box
/etc/sing-box/
endef

define Package/sing-box/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/sing-box $(1)/usr/bin/sing-box
	$(INSTALL_DIR) $(1)/etc/sing-box
	$(INSTALL_DATA) $(CURDIR)/files/ax6s-prebuilt/config.json $(1)/etc/sing-box/config.json
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_CONF) $(CURDIR)/files/sing-box.conf $(1)/etc/config/sing-box
	$(INSTALL_BIN) $(CURDIR)/files/sing-box.init $(1)/etc/init.d/sing-box
endef

$(eval $(call BuildPackage,sing-box))
'''.replace('@VERSION@', sing_version)

(naive_pkg / 'Makefile').write_text(naive_make)
(xray_pkg / 'Makefile').write_text(xray_make)
(sing_pkg / 'Makefile').write_text(sing_make)

# 显式关闭历史源码包，避免 .config 持续强制选择 libcronet。
# 修改原始配置，防止旧版源码依赖重新进入构建。
# 不调用 scripts/config，因为它在 ImmortalWrt 中是目录。
# make defconfig 将在后续工作流中重新解析依赖关系。

disabled = (
    'PACKAGE_libcronet',
    'SING_BOX_BUILD_NAIVE_OUTBOUND',
    'SING_BOX_TINY_BUILD_NAIVE_OUTBOUND',
)

config_path = ROOT / '.config'
if not config_path.is_file():
    raise RuntimeError('找不到 OpenWrt .config，无法清理旧依赖')

config_lines = config_path.read_text().splitlines()
for symbol in disabled:
    pattern = re.compile(
        r'^(?:# )?CONFIG_' + re.escape(symbol) +
        r'(?:=.*| is not set)$'
    )
    config_lines = [
        line for line in config_lines
        if not pattern.fullmatch(line)
    ]
    config_lines.append(f'# CONFIG_{symbol} is not set')

config_path.write_text('\n'.join(config_lines) + '\n')
print('[diy-part2] 已禁用本地 libcronet 和 Sing-box 源码 Naive 构建选项')


manifest = ROOT / 'ax6s-prebuilt-versions.txt'
manifest.write_text(
    'AX6S 官方预编译组件\n'
    f'NaiveProxy: v{naive_version}\n'
    f'NaiveProxy 官方归档 SHA256: {naive_digest[7:]}\n'
    f'Xray-core: v{xray_version}\n'
    f'Xray 官方归档 SHA256: {xray_digest[7:]}\n'
    f'Sing-box: v{sing_version} (linux-arm64-musl; 内置 Naive 出站)\n'
    f'Sing-box 官方归档 SHA256: {sing_digest[7:]}\n'
    f'NaiveProxy ELF SHA256: {hashlib.sha256(naive_bin).hexdigest()}\n'
    f'Xray ELF SHA256: {hashlib.sha256(xray_bin).hexdigest()}\n'
    f'Sing-box ELF SHA256: {hashlib.sha256(sing_bin).hexdigest()}\n'
)
print(manifest.read_text(), flush=True)
print('[diy-part2] 三款官方预编译软件包封装完成；已关闭本地 libcronet 选择。', flush=True)
PY

echo '[diy-part2] 全部自定义配置完成。'
