from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "branding" / "playmesh-logo.png"


def save_png(image: Image.Image, relative: str, size: int) -> None:
    target = ROOT / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    resized = image.resize((size, size), Image.Resampling.LANCZOS)
    resized.save(target, format="PNG", optimize=True)


def main() -> None:
    image = Image.open(SOURCE).convert("RGBA")

    android = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    for density, size in android.items():
        save_png(
            image,
            f"android/app/src/main/res/mipmap-{density}/ic_launcher.png",
            size,
        )

    ios = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    for name, size in ios.items():
        save_png(
            image,
            f"ios/Runner/Assets.xcassets/AppIcon.appiconset/{name}",
            size,
        )

    for size in (16, 32, 64, 128, 256, 512, 1024):
        save_png(
            image,
            f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png",
            size,
        )

    for name, size in {
        "Icon-192.png": 192,
        "Icon-512.png": 512,
        "Icon-maskable-192.png": 192,
        "Icon-maskable-512.png": 512,
    }.items():
        save_png(image, f"web/icons/{name}", size)
    save_png(image, "web/favicon.png", 32)
    save_png(
        image,
        "assets/playmesh-library/public/developer/playmesh-logo.png",
        256,
    )

    ico_target = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    image.save(
        ico_target,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )


if __name__ == "__main__":
    main()
