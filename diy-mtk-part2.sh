#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

### 1) 替换默认IP
sed -i 's#192.168.1.1#192.168.0.1#g' package/base-files/files/bin/config_generate

### 2) 调整rust版本避免编译失败（来自 coolsnowwolf）
git clone https://github.com/coolsnowwolf/packages.git
rm -rf feeds/packages/lang/rust
cp -r packages/lang/rust feeds/packages/lang
rm -rf packages

### 3) BOOST 补丁：补上 boost-system 子库 & 修正 filesystem 依赖
BOOST_MK="feeds/packages/libs/boost/Makefile"

echo "[diy-part2] 开始处理 BOOST 补丁..."
if [ -f "$BOOST_MK" ]; then
  # 3.1 插入 boost-system（若未定义）
  if ! grep -q 'DefineBoostLibrary,system' "$BOOST_MK"; then
    awk '
      BEGIN{inserted=0}
      {
        print $0
        if (!inserted && $0 ~ /\$\(eval \$\(call DefineBoostLibrary,date_time\)\)/) {
          print "$(eval $(call DefineBoostLibrary,system))"
          inserted=1
        }
      }' "$BOOST_MK" > "${BOOST_MK}.tmp" && mv "${BOOST_MK}.tmp" "$BOOST_MK"
    echo "[diy-part2] 已插入 boost-system 子库定义。"
  else
    echo "[diy-part2] 已检测到 boost-system 子库，跳过插入。"
  fi

  # 3.2 修正 filesystem 依赖，确保包含 system（避免重复添加）
  if grep -q 'DefineBoostLibrary,filesystem,atomic)' "$BOOST_MK"; then
    sed -i 's/DefineBoostLibrary,filesystem,atomic)/DefineBoostLibrary,filesystem,atomic system)/' "$BOOST_MK"
    echo "[diy-part2] 已修正 filesystem 依赖为 'atomic system'。"
  else
    awk '
      {
        line=$0
        if (line ~ /\$\(eval \$\(call DefineBoostLibrary,filesystem/ && line !~ /filesystem[^)]*system/ ) {
          sub(/\)\s*$/, " system)", line)
          print line
          next
        }
        print $0
      }' "$BOOST_MK" > "${BOOST_MK}.tmp" && mv "${BOOST_MK}.tmp" "$BOOST_MK"
    echo "[diy-part2] 已检查 filesystem 依赖，必要时补充了 system。"
  fi

  # 3.3 打印片段确认
  echo "[diy-part2] 关键片段验证："
  grep -nE 'DefineBoostLibrary,(system|filesystem)' "$BOOST_MK" | sed -n '1,8p'
else
  echo "[diy-part2] 未找到 ${BOOST_MK} 文件（feeds 可能还未 update/install），跳过 BOOST 补丁。"
fi
echo "[diy-part2] BOOST 补丁处理完成。"

# 修改gn为可编译版本
rm -rf feeds/packages/devel/gn
wget https://github.com/immortalwrt/packages/archive/a22edf48a23edfcfe212d2dbb83830d69dbb5f2f.zip -O immortalwrtPackages.zip
unzip immortalwrtPackages.zip
cp -r packages-a22edf48a23edfcfe212d2dbb83830d69dbb5f2f/devel/gn feeds/packages/devel/
rm -rf immortalwrtPackages.zip packages-a22edf48a23edfcfe212d2dbb83830d69dbb5f2f

# 修复 frp 0.68.1 编译，跳过 Web UI
FRP_MAKEFILE="feeds/packages/net/frp/Makefile"

cp "$FRP_MAKEFILE" "${FRP_MAKEFILE}.bak"

sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:=0.68.1/' "$FRP_MAKEFILE"
sed -i 's/^PKG_HASH:=.*/PKG_HASH:=44ed7107bf35e4f68dc0e77cd5805102effa5301528b89ee5ab0ab379088edc6/' "$FRP_MAKEFILE"
sed -i 's/^PKG_BUILD_DEPENDS:=golang\/host node\/host/PKG_BUILD_DEPENDS:=golang\/host/' "$FRP_MAKEFILE"

grep -q '^GO_PKG_TAGS:=noweb' "$FRP_MAKEFILE" || \
sed -i '/^GO_PKG_BUILD_PKG:=github.com\/fatedier\/frp\/cmd\/\.\.\./a GO_PKG_TAGS:=noweb' "$FRP_MAKEFILE"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("feeds/packages/net/frp/Makefile")
s = p.read_text()

new_block = """define Build/Compile
\t$(call GoPackage/Build/Compile)
endef"""

s2, count = re.subn(
    r"define Build/Compile\n.*?\nendef",
    new_block,
    s,
    count=1,
    flags=re.S,
)

if count != 1:
    raise SystemExit("failed to replace Build/Compile")

p.write_text(s2)
PY

rm -rf build_dir/target-*/frp-*
rm -rf dl/frp-0.68.1.tar.gz
