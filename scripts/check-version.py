#!/usr/bin/env python3
"""校验版本号在各处是否一致，避免"单源"只停留在文档里。

用法：python3 scripts/check-version.py

设计原因：本项目的版本唯一源是 CMakeLists.txt 的 project(... VERSION ...)，
metadata.json 由 configure_file 派生、deb 文件名由 build-deb.sh 从同一行提取，
但 CHANGELOG.md 顶部标题与 git tag 是手工维护的——三者一旦漂移，
就会出现"装的是 2.3.0、更新日志写 2.4.0、发布标签打 v2.2.0"的情况。
本脚本只读比对以下四处：
  1. CMakeLists.txt 的 project(VERSION)
  2. CHANGELOG.md 中第一个版本标题（跳过「未发布」段）
  3. 最近的 git tag（v 前缀）
  4. package/metadata.json.in 中的 @PROJECT_VERSION@ 占位是否仍在
退出码 0 表示一致，1 表示存在漂移（1/2/3 之间的差异）。
"""

import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parent.parent


def cmake_version() -> str:
    """从 CMakeLists.txt 读取 project(... VERSION x.y.z)。"""
    text = (ROOT / "CMakeLists.txt").read_text(encoding="utf-8")
    match = re.search(r"project\([^)]*VERSION\s+([0-9]+\.[0-9]+\.[0-9]+)", text)
    if not match:
        print("错误：CMakeLists.txt 中未找到 project(... VERSION ...)", file=sys.stderr)
        sys.exit(2)
    return match.group(1)


def changelog_version() -> Optional[str]:
    """取 CHANGELOG.md 中第一个形如 '## vX.Y.Z' 的标题（跳过"未发布"等非版本段）。"""
    text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    for line in text.splitlines():
        match = re.match(r"^##\s+v?([0-9]+\.[0-9]+\.[0-9]+)\b", line.strip())
        if match:
            return match.group(1)
    return None


def latest_tag() -> Optional[str]:
    """取最近的 git tag（按版本序）。"""
    try:
        out = subprocess.run(
            ["git", "tag", "--list", "v*", "--sort=-v:refname"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout.split()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return out[0].lstrip("v") if out else None


def main() -> int:
    version = cmake_version()
    log_version = changelog_version()
    tag_version = latest_tag()

    print(f"CMakeLists.txt : {version}")
    print(f"CHANGELOG.md   : {log_version or '（未找到）'}")
    print(f"最近 git tag   : {tag_version or '（无标签）'}")

    # metadata 模板必须保留占位符，否则版本会被写死
    metadata = (ROOT / "package" / "metadata.json.in").read_text(encoding="utf-8")
    if "@PROJECT_VERSION@" not in metadata:
        print("错误：package/metadata.json.in 未使用 @PROJECT_VERSION@ 占位，版本会被写死",
              file=sys.stderr)
        return 1

    problems = []
    # CHANGELOG 允许领先于 CMake（"未发布"段的下一步就是改版本号），
    # 但一旦两者都有值就必须一致，否则发布时会装上错误版本的说明
    if log_version and log_version != version:
        problems.append(f"CHANGELOG.md 顶部版本 {log_version} != CMake {version}")
    # tag 落后于当前版本是正常的（发布前尚未打标签），
    # 但 tag 超前说明版本号被回退了，属于真异常
    if tag_version and tag_version > version:
        problems.append(f"最近 tag v{tag_version} 高于当前版本 {version}")

    if problems:
        for item in problems:
            print(f"[不一致] {item}", file=sys.stderr)
        return 1

    print("[OK] 版本号一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
