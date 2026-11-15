
#!/bin/bash
# Redmi AX6S OpenWrt 自定义配置脚本（在 Feeds 安装完成后执行）
# 基于 P3TERX Actions-OpenWrt 的自定义脚本整理。

# 1. 修改默认 LAN IP 为 192.168.0.1
sed -i 's#192.168.1.1#192.168.0.1#g' package/base-files/files/bin/config_generate

# 2. 沿用原有 Rust 兼容方案：使用 coolsnowwolf 软件包仓库中的 Rust
echo '[diy-part2] Updating Rust package...'
git clone https://github.com/coolsnowwolf/packages.git
rm -rf feeds/packages/lang/rust
cp -r packages/lang/rust feeds/packages/lang
rm -rf packages

# 3. 修复 Boost：补齐 boost-system，并为 boost-filesystem 添加 system 依赖
BOOST_MK='feeds/packages/libs/boost/Makefile'
echo '[diy-part2] Checking Boost compatibility...'
if [ -f "$BOOST_MK" ]; then
  if ! grep -q 'DefineBoostLibrary,system' "$BOOST_MK"; then
    awk '
      BEGIN { inserted=0 }
      {
        print
        if (!inserted && $0 ~ /\$\(eval \$\(call DefineBoostLibrary,date_time\)\)/) {
          print "$(eval $(call DefineBoostLibrary,system))"
          inserted=1
        }
      }
    ' "$BOOST_MK" > "${BOOST_MK}.tmp" && mv "${BOOST_MK}.tmp" "$BOOST_MK"
  fi

  if grep -q 'DefineBoostLibrary,filesystem,atomic)' "$BOOST_MK"; then
    sed -i 's/DefineBoostLibrary,filesystem,atomic)/DefineBoostLibrary,filesystem,atomic system)/' "$BOOST_MK"
  else
    awk '
      {
        line=$0
        if (line ~ /\$\(eval \$\(call DefineBoostLibrary,filesystem/ && line !~ /filesystem[^)]*system/) {
          sub(/\)[[:space:]]*$/, " system)", line)
        }
        print line
      }
    ' "$BOOST_MK" > "${BOOST_MK}.tmp" && mv "${BOOST_MK}.tmp" "$BOOST_MK"
  fi

  grep -nE 'DefineBoostLibrary,(system|filesystem)' "$BOOST_MK" | sed -n '1,8p'
else
  echo '[diy-part2] Boost Makefile not found, skipping patch.'
fi

# 4. GN：保留 Feeds 提供的上游版本，仅针对 GN 主机端构建指定 GCC 12
# 新版 GN 使用 -std=c++23；部分 Runner 的默认 Clang 不支持该参数。
echo '[diy-part2] Configuring GN host compiler (GCC 12)...'
command -v gcc-12 >/dev/null 2>&1 || { echo '[diy-part2] ERROR: gcc-12 missing' >&2; exit 1; }
command -v g++-12 >/dev/null 2>&1 || { echo '[diy-part2] ERROR: g++-12 missing' >&2; exit 1; }

python3 - <<'PY'
from pathlib import Path

p = Path('feeds/packages/devel/gn/Makefile')
if not p.is_file():
    raise SystemExit('[diy-part2] ERROR: GN Makefile not found')
s = p.read_text()

replacements = (
    ('$(PYTHON) $(HOST_BUILD_DIR)/build/gen.py',
     'CC=gcc-12 CXX=g++-12 $(PYTHON) $(HOST_BUILD_DIR)/build/gen.py'),
    ('+$(NINJA) -C $(HOST_BUILD_DIR)/out gn',
     '+CC=gcc-12 CXX=g++-12 $(NINJA) -C $(HOST_BUILD_DIR)/out gn'),
)
for original, patched in replacements:
    if patched in s:
        continue
    if s.count(original) != 1:
        raise SystemExit(f'[diy-part2] ERROR: unexpected upstream GN Makefile layout: {original}')
    s = s.replace(original, patched, 1)

p.write_text(s)
print('[diy-part2] GN host build uses GCC 12; other packages remain unchanged')
PY

# 5. FRP 0.68.1：保留原有兼容补丁，跳过 Web UI 构建
echo '[diy-part2] Applying FRP compatibility patch...'
FRP_MAKEFILE='feeds/packages/net/frp/Makefile'
if [ ! -f "$FRP_MAKEFILE" ]; then
  echo '[diy-part2] ERROR: FRP Makefile not found' >&2
  exit 1
fi
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
new_block = 'define Build/Compile\n\t$(call GoPackage/Build/Compile)\nendef'
s2, count = re.subn(r'define Build/Compile\n.*?\nendef', new_block, s, count=1, flags=re.S)
if count != 1:
    raise SystemExit('[diy-part2] ERROR: FRP Build/Compile definition not found')
p.write_text(s2)
PY
rm -rf build_dir/target-*/frp-*
rm -f dl/frp-0.68.1.tar.gz

echo '[diy-part2] Patches completed.'
