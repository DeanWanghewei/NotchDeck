#!/usr/bin/env python3
"""公开目录只能宣传已有正式安装包交付的原生插件；解析适配独立发版。"""
import argparse
import json
from pathlib import Path


def version(value):
    parts = value.split(".")
    if not 1 <= len(parts) <= 3 or any(not part.isascii() or not part.isdigit() for part in parts):
        raise ValueError(f"无效版本：{value}")
    return tuple(map(int, parts)) + (0,) * (3 - len(parts))


def validate(published, released, app_version):
    delivered = {entry["id"]: entry for entry in released["plugins"]}
    for entry in published["plugins"]:
        previous = delivered.get(entry["id"])
        if previous is None or version(entry["version"]) > version(previous["version"]):
            raise ValueError(f"{entry['id']} v{entry['version']} 尚未随正式安装包交付，请只更新 bundled-catalog.json")
        if version(entry["minimumAppVersion"]) > version(app_version):
            raise ValueError(f"{entry['id']} 要求未发布的 NotchDeck {entry['minimumAppVersion']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--published", default="marketplace/catalog.json")
    parser.add_argument("--released", required=True)
    parser.add_argument("--app-version", required=True)
    args = parser.parse_args()
    try:
        validate(json.loads(Path(args.published).read_text()), json.loads(Path(args.released).read_text()), args.app_version)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"公开市场目录检查失败：{error}\n")
    print(f"公开市场目录与 NotchDeck {args.app_version} 正式版兼容")
