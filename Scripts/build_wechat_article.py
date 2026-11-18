#!/usr/bin/env python3
"""生成微信公众号文章:把模板里的图片占位符替换为 base64 内嵌,输出自包含 HTML。
用法:python3 Scripts/build_wechat_article.py
产物:docs/article/wechat-article-final.html (浏览器打开 → 全选复制 → 粘贴到公众号编辑器)
"""
import base64
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "docs/article/article-template.html"
OUTPUT = ROOT / "docs/article/wechat-article-final.html"

IMAGES = {
    "{{IMG_MAIN}}": ROOT / "docs/screenshots/screenshot-main.png",
    "{{IMG_CONFIRM}}": ROOT / "docs/screenshots/screenshot-confirm.png",
    "{{IMG_REPLACE}}": ROOT / "docs/screenshots/screenshot-replace.png",
    "{{IMG_ENCODING}}": ROOT / "docs/screenshots/screenshot-menu-encoding.png",
    "{{IMG_CODE}}": ROOT / "docs/screenshots/screenshot-code.png",
    "{{IMG_DARK}}": ROOT / "docs/screenshots/screenshot-dark.png",
}


def main() -> int:
    html = TEMPLATE.read_text(encoding="utf-8")
    total_kb = 0
    for placeholder, path in IMAGES.items():
        if not path.exists():
            print(f"警告: 缺图 {path.name},占位符保留", file=sys.stderr)
            continue
        data = base64.b64encode(path.read_bytes()).decode("ascii")
        uri = f"data:image/png;base64,{data}"
        html = html.replace(placeholder, uri)
        total_kb += len(data) // 1024
    OUTPUT.write_text(html, encoding="utf-8")
    print(f"完成: {OUTPUT}  (内嵌图片约 {total_kb} KB base64)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
