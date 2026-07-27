from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "Assets" / "Branding" / "AppIcon-source.png"


def resize_icon(icon: Image.Image, size: int) -> Image.Image:
    return icon.resize((size, size), Image.Resampling.LANCZOS)


def build_master(source: Path) -> Image.Image:
    icon = Image.open(source).convert("RGBA").resize(
        (1024, 1024), Image.Resampling.LANCZOS
    )

    # Rebuild the generated rounded-square edge as antialiased alpha so small
    # Windows and Android icons have clean corners instead of a dark matte.
    scale = 4
    mask = Image.new("L", (1024 * scale, 1024 * scale), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (0, 0, 1024 * scale - 1, 1024 * scale - 1),
        radius=246 * scale,
        fill=255,
    )
    mask = mask.resize((1024, 1024), Image.Resampling.LANCZOS)
    icon.putalpha(ImageChops.multiply(icon.getchannel("A"), mask))
    return icon


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate Windows and Android icons from the branding source."
    )
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    args = parser.parse_args()

    source = args.source.resolve()
    if not source.is_file():
        raise FileNotFoundError(source)

    assets = ROOT / "Assets"
    branding = assets / "Branding"
    branding.mkdir(parents=True, exist_ok=True)
    master = build_master(source)
    master.save(branding / "AppIcon-master.png", optimize=True)

    for filename, size in {
        "Square44x44Logo.png": 44,
        "Square150x150Logo.png": 150,
        "StoreLogo.png": 50,
    }.items():
        resize_icon(master, size).save(assets / filename, optimize=True)

    ico_path = assets / "AppIcon.ico"
    resize_icon(master, 256).save(
        ico_path,
        format="ICO",
        sizes=[
            (16, 16),
            (24, 24),
            (32, 32),
            (48, 48),
            (64, 64),
            (128, 128),
            (256, 256),
        ],
    )

    mipmap_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    android_res = ROOT / "android-app" / "android" / "app" / "src" / "main" / "res"
    for folder, size in mipmap_sizes.items():
        destination = android_res / folder
        destination.mkdir(parents=True, exist_ok=True)
        resize_icon(master, size).save(destination / "ic_launcher.png", optimize=True)

    print(f"Master: {branding / 'AppIcon-master.png'}")
    print(f"Windows ICO: {ico_path}")
    print("Windows package and Android launcher icons generated.")


if __name__ == "__main__":
    main()
