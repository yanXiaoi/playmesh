import colorsys
from pathlib import Path
import time

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
MASTER_SOURCE = ROOT / "assets" / "branding" / "playmesh-mark-master.png"
CANONICAL_MARK = ROOT / "assets" / "branding" / "playmesh-mark.png"
ICON_BACKGROUND = "#F7F8FC"
ICON_TEXT = "#253046"


def save_image(
    image: Image.Image,
    target: Path,
    *,
    format: str,
    **options,
) -> None:
    """Retry transient Windows file-open failures without changing output."""
    for attempt in range(12):
        try:
            image.save(target, format=format, **options)
            return
        except OSError as error:
            if error.errno != 22 or attempt == 11:
                raise
            time.sleep(0.15 * (attempt + 1))


def scrub_non_brand_pixels(image: Image.Image) -> Image.Image:
    """Keep only visible cyan/green/purple mark pixels; clear all backing pixels."""
    rgba = image.convert("RGBA")
    cleaned: list[tuple[int, int, int, int]] = []
    flattened = getattr(rgba, "get_flattened_data", None)
    pixels = flattened() if flattened is not None else rgba.getdata()
    for red, green, blue, alpha in pixels:
        maximum = max(red, green, blue)
        minimum = min(red, green, blue)
        saturation = 0 if maximum == 0 else (maximum - minimum) / maximum
        hue = colorsys.rgb_to_hsv(red / 255, green / 255, blue / 255)[0] * 360
        forbidden = (
            alpha < 16
            or maximum < 72
            or (saturation < 0.10 and maximum < 235)
            or (red > 150 and green > 150 and blue < 90)
            or (red > 150 and blue > 150 and green < 105)
            or (green > red * 1.35 and green > blue * 1.35 and maximum < 165)
            or (saturation >= 0.10 and not 80 <= hue <= 290)
        )
        cleaned.append((0, 0, 0, 0) if forbidden else (red, green, blue, alpha))
    rgba.putdata(cleaned)
    return rgba


def resize_rgba(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Resize premultiplied RGBA so transparent pixels cannot create dark fringes."""
    resized = (
        image.convert("RGBa")
        .resize(size, Image.Resampling.LANCZOS)
        .convert("RGBA")
    )
    return scrub_non_brand_pixels(resized)


def normalized_mark(source: Image.Image, size: int, fill: float) -> Image.Image:
    rgba = source.convert("RGBA")
    bbox = rgba.getchannel("A").getbbox()
    if bbox is None:
        raise ValueError("Playmesh mark source has no visible pixels")
    cropped = rgba.crop(bbox)
    target_extent = max(1, round(size * fill))
    scale = min(target_extent / cropped.width, target_extent / cropped.height)
    target_size = (
        max(1, round(cropped.width * scale)),
        max(1, round(cropped.height * scale)),
    )
    fitted = resize_rgba(cropped, target_size)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    offset = ((size - fitted.width) // 2, (size - fitted.height) // 2)
    canvas.alpha_composite(fitted, offset)
    return canvas


def save_png(image: Image.Image, relative: str, size: int) -> None:
    target = ROOT / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    resized = resize_rgba(image, (size, size))
    save_image(resized, target, format="PNG", optimize=True)


def solid_icon(mark: Image.Image, size: int, fill: float = 0.66) -> Image.Image:
    background = Image.new("RGBA", (size, size), ICON_BACKGROUND)
    background.alpha_composite(normalized_mark(mark, size, fill))
    return background.convert("RGB")


def save_solid_icon(mark: Image.Image, relative: str, size: int, fill: float = 0.66) -> None:
    target = ROOT / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    save_image(solid_icon(mark, size, fill), target, format="PNG", optimize=True)


def save_tv_banner(mark: Image.Image) -> None:
    target = (
        ROOT
        / "android"
        / "app"
        / "src"
        / "main"
        / "res"
        / "drawable-nodpi"
        / "playmesh_tv_banner.png"
    )
    canvas = Image.new("RGBA", (320, 180), ICON_BACKGROUND)
    logo = normalized_mark(mark, 112, 0.82)
    canvas.alpha_composite(logo, (24, 34))
    try:
        font = ImageFont.load_default(size=42)
    except TypeError:
        font = ImageFont.load_default()
    draw = ImageDraw.Draw(canvas)
    text_bbox = draw.textbbox((0, 0), "Playmesh", font=font)
    text_height = text_bbox[3] - text_bbox[1]
    draw.text((124, (180 - text_height) // 2), "Playmesh", fill=ICON_TEXT, font=font)
    save_image(canvas.convert("RGB"), target, format="PNG", optimize=True)


def write_android_adaptive_icon(mark: Image.Image) -> None:
    foreground_target = (
        ROOT
        / "android"
        / "app"
        / "src"
        / "main"
        / "res"
        / "drawable-nodpi"
        / "ic_launcher_foreground.png"
    )
    foreground_target.parent.mkdir(parents=True, exist_ok=True)
    save_image(
        normalized_mark(mark, 432, 0.56),
        foreground_target,
        format="PNG",
        optimize=True,
    )


def main() -> None:
    master = scrub_non_brand_pixels(Image.open(MASTER_SOURCE))
    save_image(master, MASTER_SOURCE, format="PNG", optimize=True)
    canonical = normalized_mark(master, 1024, 0.72)
    save_image(canonical, CANONICAL_MARK, format="PNG", optimize=True)
    # Keep the former public asset name as a transparent compatibility alias.
    save_png(canonical, "assets/branding/playmesh-logo.png", 1024)

    android = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    for density, size in android.items():
        save_solid_icon(
            canonical,
            f"android/app/src/main/res/mipmap-{density}/ic_launcher.png",
            size,
        )
    write_android_adaptive_icon(canonical)
    save_tv_banner(canonical)

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
        save_solid_icon(
            canonical,
            f"ios/Runner/Assets.xcassets/AppIcon.appiconset/{name}",
            size,
        )

    for size in (16, 32, 64, 128, 256, 512, 1024):
        save_solid_icon(
            canonical,
            f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png",
            size,
        )

    for name, size in {"Icon-192.png": 192, "Icon-512.png": 512}.items():
        save_png(canonical, f"web/icons/{name}", size)
    for name, size in {
        "Icon-maskable-192.png": 192,
        "Icon-maskable-512.png": 512,
    }.items():
        save_solid_icon(canonical, f"web/icons/{name}", size, fill=0.56)
    save_png(canonical, "web/favicon.png", 32)
    save_png(
        canonical,
        "assets/playmesh-library/public/developer/playmesh-logo.png",
        256,
    )

    ico_target = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    save_image(
        canonical,
        ico_target,
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


if __name__ == "__main__":
    main()
