#!/bin/bash

# 网络速度监控任务栏插件安装脚本

set -e

INSTALL_DIR="/usr/share/dde-shell/space.jokul.JNetApplet"

# 自动检测系统多架构 GNU 三元组（triplet），支持 amd64/arm64/loong64
# 设计原因：原硬编码 x86_64-linux-gnu 在 arm64/loong64 上会定位不到 .so。
# 该路径仅用于安装后的校验输出（真正安装位置由 CMake 决定），
# 因此探测必须逐级兜底，不能在 set -e 下因缺少 dpkg 而中断整个安装流程
DEB_ARCH=""
if command -v dpkg >/dev/null 2>&1; then
    DEB_ARCH=$(dpkg --print-architecture 2>/dev/null || true)
fi
case "$DEB_ARCH" in
    amd64)   TRIPLET="x86_64-linux-gnu" ;;
    arm64)   TRIPLET="aarch64-linux-gnu" ;;
    loong64) TRIPLET="loongarch64-linux-gnu" ;;
    *)
        # 非 Debian 系或未知架构：取编译器自带三元组，等价 CMake 侧的 CMAKE_LIBRARY_ARCHITECTURE 兜底
        TRIPLET=$(gcc -dumpmachine 2>/dev/null || echo "x86_64-linux-gnu")
        ;;
esac
SO_DIR="/usr/lib/${TRIPLET}/dde-shell"

echo "=== JNetApplet 安装脚本 ==="

# 1. 清理旧的构建目录
echo "[1/6] 清理构建目录..."
rm -rf build

# 2. 配置 + 构建
echo "[2/6] 配置 CMake 并构建..."
cmake -B build
cmake --build build

# 3. 清理安装目录中残留的旧文件（包括之前重构产生的多余 QML 文件）
echo "[3/6] 清理安装目录中的旧文件..."
if [ -d "$INSTALL_DIR" ]; then
    sudo rm -f "$INSTALL_DIR"/*.qml "$INSTALL_DIR"/*.qmlc
fi

# 4. 清理 Qt QML 磁盘缓存（关键！否则 dde-shell 可能使用旧的编译缓存）
echo "[4/6] 清理 QML 磁盘缓存..."
rm -rf ~/.cache/preloader/qmlcache/ 2>/dev/null || true
find ~/.cache -path "*/dde-shell*" -name "*.qmlc" -delete 2>/dev/null || true

# 5. 安装
echo "[5/6] 安装插件（需要 sudo）..."
sudo cmake --install build

# 验证安装结果
echo ""
echo "=== 安装验证 ==="
echo "QML 文件:"
ls -la "$INSTALL_DIR"/*.qml 2>/dev/null || echo "  [警告] 未找到 QML 文件！"
echo "动态库:"
ls -la "$SO_DIR"/space.jokul.JNetApplet.so 2>/dev/null || echo "  [警告] 未找到 .so 文件！"
echo "metadata.json 版本:"
grep '"Version"' "$INSTALL_DIR/metadata.json" 2>/dev/null || echo "  [警告] 未找到 metadata.json！"
echo ""

# 6. 重启 dde-shell
echo "[6/6] 重启 dde-shell..."
systemctl --user stop dde-shell@DDE 2>/dev/null || true
sleep 1
systemctl --user start dde-shell@DDE
echo "完成！插件已加载。"
