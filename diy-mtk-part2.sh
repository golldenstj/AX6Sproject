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

# 替换默认IP
sed -i 's#192.168.1.1#192.168.0.1#g' package/base-files/files/bin/config_generate

# 调整rust版本避免编译失败
git clone https://github.com/coolsnowwolf/packages.git
rm -rf feeds/packages/lang/rust
cp -r packages/lang/rust feeds/packages/lang
rm -rf packages
