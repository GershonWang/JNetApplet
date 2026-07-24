#!/bin/bash

# JNetApplet deb 一键打包脚本
# 用法：bash build-deb.sh
# 产物：jnetapplet_<version>_<arch>.deb

set -e

# 运行构建步骤：成功时仅显示末尾 3 行，失败时打印完整输出后返回非零
# 设计原因：原脚本用 | tail -3 管道会吞掉 find_package 等关键错误，
# 导致缺依赖时用户看不到真正原因（CMake 只在末尾报 Configuring incomplete）
run_step() {
    local desc="$1"; shift
    local log
    log=$(mktemp)
    if "$@" > "$log" 2>&1; then
        tail -3 "$log"
        rm -f "$log"
        return 0
    else
        echo "错误：${desc}失败，完整输出如下：" >&2
        cat "$log" >&2
        rm -f "$log"
        return 1
    fi
}

# 项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 从 CMakeLists.txt 读取版本号
VERSION=$(grep -oP 'project\([^)]*VERSION\s+\K[0-9]+\.[0-9]+\.[0-9]+' CMakeLists.txt)
if [ -z "$VERSION" ]; then
    echo "错误：无法从 CMakeLists.txt 读取版本号"
    exit 1
fi

# 架构判断
ARCH=$(dpkg --print-architecture)
if [ -z "$ARCH" ]; then
    ARCH="amd64"
fi

PKG_NAME="jnetapplet"
DEB_FILE="${PKG_NAME}_${VERSION}_${ARCH}.deb"

echo "=========================================="
echo "  JNetApplet deb 打包"
echo "  版本: $VERSION"
echo "  架构: $ARCH"
echo "  产物: $DEB_FILE"
echo "=========================================="

# 检查依赖工具
for cmd in cmake dpkg-deb; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "错误：缺少 $cmd，请先安装"
        exit 1
    fi
done

echo "[1/6] 检查构建依赖..."

# 检查构建依赖：确认开发包已安装，缺失时提示安装命令并退出
# 设计原因：用户 clone 后直接运行 build-deb.sh 经常因缺少 -dev 包导致
# CMake 配置失败，但原脚本用 tail -3 吞掉关键错误，用户无法定位问题。
# 在构建前主动预检可提前给出明确指引。
DEPS=(qt6-base-dev qt6-declarative-dev libdtkcommon-dev libdtk6gui-dev libxkbcommon-dev libdde-shell-dev)
MISSING=()
for pkg in "${DEPS[@]}"; do
    if ! dpkg -s "$pkg" &> /dev/null 2>&1; then
        MISSING+=("$pkg")
    fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "错误：缺少构建依赖包：${MISSING[*]}" >&2
    echo "请执行以下命令安装：" >&2
    echo "  sudo apt install ${MISSING[*]} build-essential cmake" >&2
    exit 1
fi
echo "所有构建依赖已就绪"

# 清理并创建构建目录
echo "[2/6] 构建 CMake 项目..."
rm -rf build
run_step "CMake 配置" cmake -B build -S . -DCMAKE_BUILD_TYPE=Release || exit 1
run_step "CMake 构建" cmake --build build -j"$(nproc)" || exit 1

# 创建 staging 目录（模拟安装根目录）
STAGE_DIR="$(mktemp -d)"
trap "rm -rf '$STAGE_DIR'" EXIT

echo "[3/6] 安装到 staging 目录..."
# DESTDIR 指定安装根目录前缀，cmake 会将 /usr/... 安装到 $STAGE_DIR/usr/...
run_step "安装到 staging" env DESTDIR="$STAGE_DIR" cmake --install build || exit 1

# 生成 DEBIAN/control
echo "[4/6] 生成 control 文件..."
mkdir -p "$STAGE_DIR/DEBIAN"

# 计算安装后大小（KB）
INSTALLED_SIZE=$(du -sk "$STAGE_DIR/usr" | cut -f1)

cat > "$STAGE_DIR/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: Jokul <jokul@git.jokul.space>
Installed-Size: ${INSTALLED_SIZE}
Depends: dde-shell, libc6, libqt6core6, libqt6gui6, libqt6quick6, libqt6network6, libdtk6core
Section: utils
Priority: optional
Description: 网络速度监控 dde-shell 任务栏插件
 实时监控网络下载/上传速度，支持多网卡切换、IP 地址显示、
 总流量统计。适用于 deepin 桌面环境的 dde-shell 任务栏。
Homepage: https://git.jokul.space/Jokul/JNetApplet
EOF

# 生成 postinst 脚本：安装后重启桌面用户的 dde-shell
# 注意：dpkg 以 root 运行此脚本，systemctl --user 需切换到桌面用户身份
cat > "$STAGE_DIR/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
# 找到活跃桌面用户（UID >= 1000），以其身份重启 dde-shell 用户服务
for user in $(who | awk '{print $1}' | sort -u); do
    [ "$user" = "root" ] && continue
    uid=$(id -u "$user" 2>/dev/null) || continue
    [ "$uid" -lt 1000 ] && continue
    su "$user" -c "systemctl --user restart dde-shell@DDE" 2>/dev/null || true
done
exit 0
EOF
chmod 755 "$STAGE_DIR/DEBIAN/postinst"

# 生成 prerm 脚本：卸载前重启桌面用户的 dde-shell 移除插件
cat > "$STAGE_DIR/DEBIAN/prerm" << 'EOF'
#!/bin/bash
set -e
# 以桌面用户身份重启 dde-shell 以卸载插件
for user in $(who | awk '{print $1}' | sort -u); do
    [ "$user" = "root" ] && continue
    uid=$(id -u "$user" 2>/dev/null) || continue
    [ "$uid" -lt 1000 ] && continue
    su "$user" -c "systemctl --user restart dde-shell@DDE" 2>/dev/null || true
done
exit 0
EOF
chmod 755 "$STAGE_DIR/DEBIAN/prerm"

# 修正文件权限（so 文件需要 755，qml/json 需要 644）
echo "[5/6] 修正文件权限..."
find "$STAGE_DIR/usr" -type f -name "*.so" -exec chmod 755 {} \;
find "$STAGE_DIR/usr" -type f \( -name "*.qml" -o -name "*.json" \) -exec chmod 644 {} \;

# 构建 deb
echo "[6/6] 构建 deb 包..."
rm -f "$DEB_FILE"
dpkg-deb --build --root-owner-group "$STAGE_DIR" "$DEB_FILE"

echo ""
echo "=========================================="
echo "  打包完成！"
echo "  产物: $DEB_FILE ($(du -h "$DEB_FILE" | cut -f1))"
echo ""
echo "  安装: sudo dpkg -i $DEB_FILE"
echo "  卸载: sudo dpkg -r $PKG_NAME"
echo "=========================================="
