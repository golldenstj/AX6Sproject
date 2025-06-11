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
# 删除 download-ci-llvm 的设置（无论 true 或 if-unchanged）
sed -i 's/--set=llvm\.download-ci-llvm=.*\\/--set=llvm.download-ci-llvm=false \\/' feeds/packages/lang/rust/Makefile
# 添加 --set=llvm.build=true 到其下一行
sed -i '/--set=llvm\.download-ci-llvm=false \\/a \ \ \ \ --set=llvm.build=true \\' feeds/packages/lang/rust/Makefile
# 删除已废弃且报错的 bootstrap-cache-path
sed -i '/--set=build\.bootstrap-cache-path=/d' feeds/packages/lang/rust/Makefile

