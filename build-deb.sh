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
# dpkg 已由下方依赖工具预检保证存在，故不再需要空值兜底
# （原 if [ -z "$ARCH" ] 兜底在 set -e 下不可达，属死代码）
ARCH=$(dpkg --print-architecture)

PKG_NAME="jnetapplet"
DEB_FILE="${PKG_NAME}_${VERSION}_${ARCH}.deb"

echo "=========================================="
echo "  JNetApplet deb 打包"
echo "  版本: $VERSION"
echo "  架构: $ARCH"
echo "  产物: $DEB_FILE"
echo "=========================================="

# 检查依赖工具
# dpkg 用于读取系统架构（见上方"架构判断"），必须与 cmake/dpkg-deb 一并预检，
# 否则在 set -e 下会以 "dpkg: command not found" 直接中断，用户看不到友好提示
for cmd in cmake dpkg dpkg-deb; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "错误：缺少 $cmd，请先安装"
        exit 1
    fi
done

echo "[1/7] 检查构建依赖..."

# 检查构建依赖：确认开发包已安装，缺失时提示安装命令并退出
# 设计原因：用户 clone 后直接运行 build-deb.sh 经常因缺少 -dev 包导致
# CMake 配置失败，但原脚本用 tail -3 吞掉关键错误，用户无法定位问题。
# 在构建前主动预检可提前给出明确指引。
# 依赖清单与 CMakeLists.txt 的 find_package 逐项对应（包名取自 dpkg 数据库核实）：
#   Qt6 Core/Quick/Network -> qt6-base-dev, qt6-declarative-dev
#   Qt6 LinguistTools      -> qt6-tools-dev          ← 曾遗漏，导致"预检通过、配置失败"
#   Dtk6 Core              -> libdtk6core-dev, libdtkcommon-dev
#   DDEShell               -> libdde-shell-dev
#   间接依赖                -> libdtk6gui-dev（DDEShell 依赖）、libxkbcommon-dev（Qt6 Gui 依赖）
# 注意：新增 find_package 时必须同步此处，否则用户按提示装完仍会在配置阶段失败
DEPS=(qt6-base-dev qt6-declarative-dev qt6-tools-dev \
      libdtk6core-dev libdtkcommon-dev libdtk6gui-dev \
      libxkbcommon-dev libdde-shell-dev)
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
echo "[2/7] 构建 CMake 项目..."
rm -rf build
run_step "CMake 配置" cmake -B build -S . -DCMAKE_BUILD_TYPE=Release || exit 1
run_step "CMake 构建" cmake --build build -j"$(nproc)" || exit 1

# 创建 staging 目录（模拟安装根目录）
STAGE_DIR="$(mktemp -d)"
trap "rm -rf '$STAGE_DIR'" EXIT

echo "[3/7] 安装到 staging 目录..."
# DESTDIR 指定安装根目录前缀，cmake 会将 /usr/... 安装到 $STAGE_DIR/usr/...
run_step "安装到 staging" env DESTDIR="$STAGE_DIR" cmake --install build || exit 1

# 生成 DEBIAN/control
# 注意：Maintainer 字段只保留姓名。原邮箱绑定的是已停用的 git.jokul.space 域名，
# 在提供新邮箱之前不写入邮箱地址（Debian 规范建议该字段含邮箱，规范检查工具可能提示缺失）
echo "[4/7] 生成 control 文件..."
mkdir -p "$STAGE_DIR/DEBIAN"

# 计算安装后大小（KB）
INSTALLED_SIZE=$(du -sk "$STAGE_DIR/usr" | cut -f1)

# Depends 只列"dde-shell 未覆盖"的直接依赖。
# 逐项核实过（.so 的 NEEDED × 宿主 dpkg 数据库 × dde-shell 的 Depends 链）：
#   插件 NEEDED：libdde-shell / libQt6Network / libdtk6core / libQt6Gui /
#                libQt6DBus / libQt6Core / libstdc++ / libgcc_s / libc
#   其中 libdde-shell、libQt6Core/Gui/DBus、libdtk6core、libstdc++6、
#   libgcc-s1、libc6 均已在 dde-shell 主包的 Depends 中声明（传递覆盖）；
#   **libqt6network6 不在其中**，必须本级声明，否则干净系统上装完无法加载。
# 原清单的问题：libqt6quick6 并不在本 .so 的 NEEDED 里（多余），
# 而 dde-shell 已覆盖的项又被重复列出。现按实际 NEEDED 收敛——
# 声明用不到的包会给用户增加无谓的安装体积与解析时间。
cat > "$STAGE_DIR/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: Jokul
Installed-Size: ${INSTALLED_SIZE}
Depends: dde-shell, libqt6network6
Section: utils
Priority: optional
Description: 网络速度监控 dde-shell 任务栏插件
 实时监控网络下载/上传速度，支持多网卡切换、IP 地址显示、
 总流量统计。适用于 deepin 桌面环境的 dde-shell 任务栏。
Homepage: https://github.com/GershonWang/JNetApplet
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

# ---- 许可证与变更记录（Debian 政策要求随包分发）----
# 设计原因：源码各处 SPDX 头声明 LGPL-3.0-or-later，但仓库此前没有 LICENSE 文件，
# deb 里也没有 /usr/share/doc/<pkg>/{copyright,changelog.Debian.gz}，
# 既违反 LGPL"随分发提供许可证"的要求，lintian 也会报 no-copyright-file / no-changelog。
# copyright 采用 Debian DEP-5 机器可读格式，便于 apt-file / licensecheck 等工具解析
echo "[5/7] 写入版权与变更记录..."
DOC_DIR="$STAGE_DIR/usr/share/doc/$PKG_NAME"
mkdir -p "$DOC_DIR"

# heredoc 使用带引号的 'EOF'：内容里的 <https://...> 与任何 $ 字符都原样写入，
# 避免被 shell 展开（许可证文本必须逐字准确）
cat > "$DOC_DIR/copyright" << 'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: JNetApplet
Upstream-Contact: Jokul
Source: https://github.com/GershonWang/JNetApplet

Files: *
Copyright: 2026 Jokul
License: LGPL-3.0-or-later
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.
 .
 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Lesser General Public License for more details.
 .
 You should have received a copy of the GNU Lesser General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 .
 On Debian systems, the complete text of the GNU Lesser General Public
 License version 3 can be found in /usr/share/common-licenses/LGPL-3.
EOF
chmod 644 "$DOC_DIR/copyright"

# changelog.Debian 由仓库 CHANGELOG.md 生成，避免手工维护第二份变更记录导致版本说明漂移。
# 规则：取 CHANGELOG.md 中第一个版本标题（"## ..."）与其下的列表条目，
# 去掉 Markdown 强调标记后逐条转为 Debian changelog 的 "  * " 条目；
# 头部与尾部的签名行必须符合 Debian 格式，否则 dpkg 解析会失败
CHANGELOG_ENTRIES=$(
    awk '
        /^## / { if (seen) exit; seen = 1; next }   # 只取第一个版本段落
        seen && /^### / { next }                    # 跳过 "### 修复" 之类小标题
        seen && /^- /   { print "  * " substr($0, 3) }
        seen && /^  - / { print "    " substr($0, 5) }
    ' CHANGELOG.md | sed -e 's/\*\*//g' -e 's/`//g'
)
# 极端情况下（CHANGELOG 结构被改坏）也要给出合法条目，避免生成空 changelog
[ -n "$CHANGELOG_ENTRIES" ] || CHANGELOG_ENTRIES="  * 详见上游 CHANGELOG.md"

{
    printf '%s (%s) unstable; urgency=medium\n\n' "$PKG_NAME" "$VERSION"
    printf '%s\n' "$CHANGELOG_ENTRIES"
    printf '\n -- %s  <%s>  %s\n' "Jokul" "noreply@example.com" "$(date -R)"
} > "$DOC_DIR/changelog.Debian"
gzip -9n -f "$DOC_DIR/changelog.Debian"
chmod 644 "$DOC_DIR/changelog.Debian.gz"

# 修正文件权限（so 文件需要 755，qml/json 需要 644）
echo "[6/7] 修正文件权限..."
find "$STAGE_DIR/usr" -type f -name "*.so" -exec chmod 755 {} \;
find "$STAGE_DIR/usr" -type f \( -name "*.qml" -o -name "*.json" \) -exec chmod 644 {} \;

# 构建 deb
echo "[7/7] 构建 deb 包..."
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
