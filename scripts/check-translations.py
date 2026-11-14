#!/usr/bin/env python3
"""校验 translations/*.ts 与 QML/C++ 源码中的 qsTr() 源串是否同步。

用法：python3 scripts/check-translations.py [--fix-report]

设计原因：仓库没有 CI 可用的 lupdate（GitHub runner 无 deepin/Qt 环境，
本地宿主 lupdate 又依赖完整 libclang），翻译文件长期靠手工维护。
缺少校验时新增文案会静默漏译，而 qsTr() 源串本身是英文——漏译在中文环境
直接表现为界面出现英文，属于用户可见缺陷。

本脚本只做只读比对，输出：
  - 源码中有、.ts 中没有的源串（漏译，必须修）
  - .ts 中有、源码中已不存在的源串（陈旧条目，建议清理）
退出码 1 表示存在漏译，0 表示同步。
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TS_FILE = ROOT / "translations" / "jnetapplet_zh_CN.ts"

# 匹配 qsTr("...") 与 QObject::tr("...")，允许字符串内含转义引号；
# 不处理跨多行的罕见写法。
# 同时匹配 tr() 的原因：C++ 侧的系统通知文案也用 tr() 走同一套翻译，
# 只查 qsTr 会让"代码里有 tr、.ts 里没有"的漏译悄悄溜过去
QSTR_RE = re.compile(r'(?:qsTr|(?<![\w.])tr)\(\s*"((?:[^"\\]|\\.)*)"')


def collect_sources() -> dict[str, list[str]]:
    """收集源码中的 qsTr 源串，按文件归类，便于定位漏译出处。"""
    found: dict[str, list[str]] = {}
    patterns = ["package/**/*.qml", "src/**/*.cpp"]
    for pattern in patterns:
        for path in sorted(ROOT.glob(pattern)):
            text = path.read_text(encoding="utf-8", errors="replace")
            for match in QSTR_RE.finditer(text):
                # .ts 里存的是未转义的字面量，这里还原常见转义
                literal = match.group(1).replace('\\"', '"').replace("\\\\", "\\")
                found.setdefault(literal, []).append(str(path.relative_to(ROOT)))
    return found


def collect_translations() -> set[str]:
    """读取 .ts 中所有 <source> 文本（含已标记 vanished 的条目）。"""
    if not TS_FILE.exists():
        print(f"错误：找不到翻译文件 {TS_FILE}", file=sys.stderr)
        sys.exit(2)
    tree = ET.parse(TS_FILE)
    return {(node.text or "") for node in tree.iter("source")}


def main() -> int:
    sources = collect_sources()
    translated = collect_translations()

    missing = sorted(set(sources) - translated)
    source_set = set(sources)
    obsolete = sorted(translated - source_set)

    if missing:
        print(f"[漏译] {len(missing)} 条源码文案在 .ts 中不存在：")
        for text in missing:
            where = ", ".join(sorted(set(sources[text])))
            print(f"  - {text!r}  <- {where}")
    else:
        print(f"[OK] 源码中 {len(source_set)} 条文案均已收录于 .ts")

    if obsolete:
        print(f"[陈旧] {len(obsolete)} 条 .ts 条目的源串已不在源码中（建议删除）：")
        for text in obsolete:
            print(f"  - {text!r}")

    # 只有漏译会让用户看到英文，因此只把漏译视为失败
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
