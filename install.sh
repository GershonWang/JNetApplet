#!/bin/bash

# 网络速度监控任务栏插件安装脚本

set -e

echo "Building JNetApplet..."

# 清理旧的构建目录
rm -rf build

# 配置CMake
cmake -Bbuild

# 构建
cmake --build build

echo "Installing JNetApplet (requires sudo)..."

# 安装
sudo cmake --install build

echo "Installation complete!"
echo "Please restart dde-shell to load the plugin:"
echo "  systemctl --user restart dde-shell@DDE"