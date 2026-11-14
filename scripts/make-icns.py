#!/usr/bin/env python3
"""把一张 1024×1024 的 PNG 打成 macOS 的 .icns（不放 iconutil）。

    python3 scripts/make-icns.py icons/mytype/app-1024.png dist/AppIcon.icns

iconutil 依赖系统的图标服务和目录服务，偶尔会在整机层面失灵（`Invalid Iconset`），
打包不该被它卡住：.icns 就是一串「类型 + 长度 + PNG 数据」的块，这里自己写。
尺寸用 sips 缩（系统自带），每个尺寸对应一个 icns 类型。
"""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# icns 类型 -> 像素边长。苹果的 PNG 变体：icp4/5/6、ic07..ic14。
SIZES = [
    ("icp4", 16),
    ("ic11", 32),   # 16@2x
    ("icp5", 32),
    ("ic12", 64),   # 32@2x
    ("ic07", 128),
    ("ic13", 256),  # 128@2x
    ("ic08", 256),
    ("ic14", 512),  # 256@2x
    ("ic09", 512),
    ("ic10", 1024),  # 512@2x
]


def png_bytes(source: Path, side: int, workdir: Path) -> bytes:
    out = workdir / f"icon_{side}.png"
    subprocess.run(
        ["sips", "-z", str(side), str(side), str(source), "--out", str(out)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    data = out.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"sips 没能把 {source} 缩成 {side}×{side} 的 PNG")
    return data


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    source, target = Path(argv[1]), Path(argv[2])
    if not source.is_file():
        raise SystemExit(f"没有这个文件：{source}")
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        chunks = []
        for kind, side in SIZES:
            data = png_bytes(source, side, workdir)
            chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
        body = b"".join(chunks)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print(f"{target}（{target.stat().st_size // 1024} KB，{len(SIZES)} 档）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
