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

# Rust 编译器参数改成 download-ci-llvm = false，自己编译 LLVM
# ✅ 1. 将 --set=llvm.download-ci-llvm=xxx 改为 false（无论是 true 还是 if-unchanged）
sed -i 's/--set=llvm\.download-ci-llvm=.*\\/--set=llvm.download-ci-llvm=false \\/' feeds/packages/lang/rust/Makefile
# ✅ 2. 在其下一行添加 --set=llvm.build=true
sed -i '/--set=llvm\.download-ci-llvm=false \\/a \ \ \ \ --set=llvm.build=true \\' feeds/packages/lang/rust/Makefile
# ✅ 3. 删除 legacy 的 --set=build.bootstrap-cache-path 行（此字段已被 Rust 移除）
sed -i '/--set=build\.bootstrap-cache-path=/d' feeds/packages/lang/rust/Makefile
# ✅ 4. 删除 configure.py 不认识的 --bootstrap-cache-path 参数（这是根本报错源头）
sed -i '/--bootstrap-cache-path=/d' feeds/packages/lang/rust/Makefile
