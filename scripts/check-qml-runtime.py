#!/usr/bin/env python3
"""检查 QML 的三类"只在运行时炸"的错误。

用法：
    python3 scripts/check-qml-runtime.py            # 用本机 Qt 模块推断
    python3 scripts/check-qml-runtime.py --qml-dir /path/to/qml

背景（真实事故，均导致插件从任务栏彻底消失）：

  1. `import QtQuick.Dialogs 1.3` —— Qt6 的该模块只导出 6.2+，
     版本号沿用 Qt5 的写法，加载时直接失败。
  2. `ColumnLayout { topPadding: 16 }` —— 布局容器没有 padding 属性
     （那是 Control 的），一行属性写错使整个窗口类型不可用。
  3. `AppletItem { activeFocusOnTab: true }` —— AppletItem 是 dde-shell 的
     C++ 注册类型，QML 侧未暴露该属性，根节点赋值失败导致入口 QML 加载失败。

三类错误分别由谁拦：
  - 第 1 类（import 版本）：本脚本的 import 校验；
  - 第 2 类（标准 Qt 属性）：qmllint 的 missing-property 告警（见 CI 的 qml-property job）；
  - 第 3 类（dde-shell 注册类型属性）：本脚本的属性白名单。
本脚本负责第 1、3 类：
  - 第 1 类：把 import 版本与该模块实际导出的版本比对；
  - 第 3 类：dde-shell 注册类型的属性白名单（按实测可用集合维护）。

退出码 1 表示发现问题。
"""

import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# dde-shell C++ 注册类型的 QML 可用属性白名单。
#
# 为什么需要硬编码：这些类型由 dde-shell 的 .so 注册，没有 .qmltypes 可供
# 自动推导（AppletItem 对应 ds::DAppletItem，基类 QQuickItem），
# 而 qmllint 在缺 deepin 模块时会把这些属性一律报成"不存在"（全是噪声）。
# 因此这里按**真机可用**的集合维护：往根节点加属性前先对照本表。
#
# 实测记录：activeFocusOnTab / Keys.on*Pressed 在 AppletItem 上不可用，
# 写上去会让入口 QML 加载失败（见 networkview.qml 的注释）。
DDE_REGISTERED_TYPES = {
    "AppletItem": {
        "allowed": {
            "objectName", "implicitWidth", "implicitHeight", "width", "height",
            "visible", "enabled", "anchors", "Layout", "parent", "data",
            # 插件坐标系与任务栏上下文
            "dockOrder", "dockSize", "isVerticalDock",
            # 无障碍：这三个是 QML 通用附加属性，AppletItem 上可用
            "Accessible", "Accessible.role", "Accessible.name",
            "Accessible.onPressAction",
        },
        # 明确不可用、且写上去会导致加载失败的属性
        "forbidden": {"activeFocusOnTab", "Keys"},
    },
}

# import 时允许不带版本号的模块（QML 允许省略，取最新）
NO_VERSION_REQUIRED = {"Qt.labs.platform"}


def iter_qml_files(package_dir: Path):
    yield from sorted(package_dir.glob("*.qml"))
    yield from sorted((package_dir / "components").glob("*.qml"))


def strip_comments(text: str) -> str:
    """去掉行注释，避免把注释里举例的错误写法当成真代码。"""
    return "\n".join(re.sub(r"//.*", "", line) for line in text.split("\n"))


def check_imports(package_dir: Path, qml_root: Path | None):
    """检查 import 版本号是否真实存在。

    原理：Qt 模块目录下的 plugins.qmltypes 里记录了 exports 的版本，
    例如 `exports: ["QtQuick.Dialogs/FileDialog 6.2"]`。
    若某模块的导出集合里所有版本都低于 import 声明的版本，即为错误。
    """
    problems = []
    imports = {}
    for path in iter_qml_files(package_dir):
        for lineno, line in enumerate(strip_comments(path.read_text(encoding="utf-8")).split("\n"), 1):
            m = re.match(r"\s*import\s+([\w.]+)(?:\s+([\d.]+))?(?:\s+as\s+\w+)?\s*$", line)
            if not m:
                continue
            module, version = m.group(1), m.group(2)
            imports.setdefault((module, version), []).append((path, lineno))

    for (module, version), uses in sorted(imports.items()):
        if version is None:
            if module in NO_VERSION_REQUIRED:
                continue
            problems.append(
                f"  {module} 缺少版本号（{uses[0][0].name}:{uses[0][1]}）"
            )
            continue
        if module.startswith("org.deepin"):
            # deepin 模块不提供可解析的版本元数据，跳过（由 qmllint 与真机兜底）
            continue
        if qml_root is None or not qml_root.exists():
            continue
        mod_path = qml_root / module.replace(".", "/")
        if not mod_path.exists():
            continue   # 模块本身缺失不在此处判定
        versions = collect_export_versions(mod_path)
        if not versions:
            continue
        wanted_major = int(version.split(".")[0])
        # QML 的版本判定以**主版本**为准：
        #   - Qt6 的模块会保留对旧主版本的兼容导出，且不校验次版本上限
        #     （因此 `QtQuick.Layouts 1.15` 合法：该模块有 1.x 导出）；
        #   - 反过来若模块根本没有该主版本，import 一定失败
        #     （`QtQuick.Dialogs 1.3` 失败：该模块只有 6.x）。
        # 刻意不比较次版本：Qt 对次版本是宽松的，卡次版本会产生大量误报
        #（例如 Layouts 导出上限是 1.3，但 1.15 实际可用）。
        majors = sorted({v[0] for v in versions})
        if wanted_major not in majors:
            problems.append(
                f"  {module} {version} 不存在（{mod_path.name} 没有主版本 "
                f"{wanted_major}，仅导出主版本 {majors}）"
                f" <- {uses[0][0].name}:{uses[0][1]}"
            )
    return problems


def collect_export_versions(mod_path: Path) -> set[tuple[int, ...]]:
    """从模块的 qmltypes 里收集所有 exports 版本。"""
    versions = set()
    for qmltypes in list(mod_path.glob("*.qmltypes")) + list(mod_path.glob("*/*.qmltypes")):
        try:
            text = qmltypes.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        # exports 可能是单行 ["a 1.0", "b 2.0"]，也可能是跨多行的数组；
        # 用 re.S 让 [^\]] 跨行匹配，否则只会读到第一行的一两条（曾因此漏判）
        for m in re.finditer(r"exports:\s*\[([^\]]+)\]", text, re.S):
            for item in m.group(1).split(","):
                vm = re.search(r"(\d+)\.(\d+)", item)
                if vm:
                    versions.add((int(vm.group(1)), int(vm.group(2))))
    # qmldir 里只认「组件声明行」（形如 `Name 1.0 Name.qml`）携带的版本；
    # depends/prefer/plugin 等行里的数字不属于本模块导出，混入会污染判定
    try:
        for line in (mod_path / "qmldir").read_text(encoding="utf-8", errors="replace").split("\n"):
            if re.match(r"^(module|plugin|classname|typeinfo|depends|prefer|linktarget|"
                        r"optional|designersupported|internal)\b", line.strip()):
                continue
            parts = line.split()
            if len(parts) >= 2 and re.fullmatch(r"\d+\.\d+", parts[1]):
                versions.add(tuple(int(x) for x in parts[1].split(".")))
    except OSError:
        pass
    return versions


def check_dde_type_properties(package_dir: Path):
    """检查 dde-shell 注册类型上是否写了实测不可用的属性。"""
    problems = []
    for path in iter_qml_files(package_dir):
        text = strip_comments(path.read_text(encoding="utf-8"))
        lines = text.split("\n")
        for idx, line in enumerate(lines):
            m = re.match(r"\s*(\w+)\s*\{\s*$", line)
            if not m or m.group(1) not in DDE_REGISTERED_TYPES:
                continue
            type_name = m.group(1)
            spec = DDE_REGISTERED_TYPES[type_name]
            # 检查该类型块内（到同缩进的 }）的属性
            base_indent = len(line) - len(line.lstrip())
            for j in range(idx + 1, len(lines)):
                cur = lines[j]
                if cur.strip() == "}" and (len(cur) - len(cur.lstrip())) == base_indent:
                    break
                pm = re.match(r"\s*(\w+(?:\.\w+)?)\s*:", cur)
                if not pm:
                    continue
                prop = pm.group(1)
                head = prop.split(".")[0]
                if head in spec["forbidden"] or prop in spec["forbidden"]:
                    problems.append(
                        f"  {path.name}:{j + 1} {type_name}.{prop} 实测不可用，"
                        f"会导致入口 QML 加载失败"
                    )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qml-dir", default=os.environ.get("QML_IMPORT_PATH"),
                        help="Qt QML 模块根目录（用于校验 import 版本）")
    parser.add_argument("--package-dir", default=str(ROOT / "package"))
    args = parser.parse_args()

    package_dir = Path(args.package_dir)
    qml_root = Path(args.qml_dir) if args.qml_dir else None

    # 显式指定了模块根却不存在：这是环境配置错误，必须报错。
    # 否则 CI 里装包失败（或路径写错）时，import 校验会静默跳过并"通过"，
    # 检查就退化成了摆设。
    if qml_root is not None and not qml_root.is_dir():
        print(f"[错误] 指定的 QML 模块根目录不存在：{qml_root}")
        return 1

    failed = False

    problems = check_imports(package_dir, qml_root)
    if problems:
        print("[import 版本]")
        print("\n".join(problems))
        failed = True
    elif qml_root:
        print(f"[OK] import 版本校验通过（模块根：{qml_root}）")
    else:
        print("[跳过] import 版本校验：未提供 --qml-dir / QML_IMPORT_PATH")

    problems = check_dde_type_properties(package_dir)
    if problems:
        print("[dde-shell 注册类型属性]")
        print("\n".join(problems))
        failed = True
    else:
        print("[OK] dde-shell 注册类型未使用实测不可用的属性")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
