from __future__ import annotations

import colorsys
from collections import deque
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
BACKGROUND = (247, 248, 252)


class ContractError(AssertionError):
    pass


def load(relative: str) -> Image.Image:
    path = ROOT / relative
    if not path.is_file():
        raise ContractError(f"missing brand asset: {relative}")
    return Image.open(path)


def assert_size(relative: str, expected: tuple[int, int]) -> None:
    with load(relative) as image:
        if image.size != expected:
            raise ContractError(
                f"{relative}: expected {expected[0]}x{expected[1]}, got {image.size}"
            )


def visible_bbox(image: Image.Image, threshold: int = 16) -> tuple[int, int, int, int]:
    alpha = image.convert("RGBA").getchannel("A")
    mask = alpha.point(lambda value: 255 if value >= threshold else 0)
    bbox = mask.getbbox()
    if bbox is None:
        raise ContractError("brand mark has no visible pixels")
    return bbox


def assert_transparent_mark(
    relative: str,
    expected_size: tuple[int, int] | None = None,
    *,
    validate_geometry: bool = False,
) -> None:
    with load(relative) as source:
        if expected_size is not None and source.size != expected_size:
            raise ContractError(
                f"{relative}: expected {expected_size}, got {source.size}"
            )
        image = source.convert("RGBA")
        alpha = image.getchannel("A")
        if alpha.getextrema() != (0, 255):
            raise ContractError(f"{relative}: must contain both transparent and opaque pixels")
        width, height = image.size
        corners = (
            alpha.getpixel((0, 0)),
            alpha.getpixel((width - 1, 0)),
            alpha.getpixel((0, height - 1)),
            alpha.getpixel((width - 1, height - 1)),
        )
        if corners != (0, 0, 0, 0):
            raise ContractError(f"{relative}: all four corners must be fully transparent")

        if validate_geometry:
            left, top, right, bottom = visible_bbox(image)
            margins = (left / width, top / height, (width - right) / width, (height - bottom) / height)
            if min(margins) < 0.10 or max(margins) > 0.22:
                raise ContractError(
                    f"{relative}: expected 10%-22% safe padding, got {margins}"
                )
            visible_pixels = sum(1 for value in pixel_values(alpha) if value >= 16)
            coverage = visible_pixels / (width * height)
            if not 0.12 <= coverage <= 0.42:
                raise ContractError(f"{relative}: implausible visible coverage {coverage:.3f}")
            assert_three_transparent_holes(relative, image)

        assert_brand_color_boundary(relative, image)


def assert_three_transparent_holes(relative: str, image: Image.Image) -> None:
    reduced = image.getchannel("A").resize((256, 256), Image.Resampling.NEAREST)
    transparent = [value < 16 for value in pixel_values(reduced)]
    visited = bytearray(256 * 256)
    enclosed_areas: list[int] = []
    for start, is_transparent in enumerate(transparent):
        if not is_transparent or visited[start]:
            continue
        queue: deque[int] = deque([start])
        visited[start] = 1
        touches_border = False
        area = 0
        while queue:
            index = queue.popleft()
            x = index % 256
            y = index // 256
            area += 1
            if x == 0 or y == 0 or x == 255 or y == 255:
                touches_border = True
            for next_index in (index - 1, index + 1, index - 256, index + 256):
                if next_index < 0 or next_index >= 256 * 256:
                    continue
                next_x = next_index % 256
                if abs(next_x - x) > 1:
                    continue
                if transparent[next_index] and not visited[next_index]:
                    visited[next_index] = 1
                    queue.append(next_index)
        if not touches_border and area >= 100:
            enclosed_areas.append(area)
    node_holes = [area for area in enclosed_areas if 100 <= area <= 1000]
    central_negative_space = [area for area in enclosed_areas if area > 1000]
    if len(node_holes) != 3 or not central_negative_space:
        raise ContractError(
            f"{relative}: expected 3 transparent node holes plus central negative space, "
            f"got {enclosed_areas}"
        )


def assert_brand_color_boundary(relative: str, image: Image.Image) -> None:
    forbidden = 0
    samples: list[tuple[int, int, int, int]] = []
    for red, green, blue, alpha in pixel_values(image):
        if alpha < 16:
            continue
        maximum = max(red, green, blue)
        minimum = min(red, green, blue)
        saturation = 0 if maximum == 0 else (maximum - minimum) / maximum
        hue = colorsys.rgb_to_hsv(red / 255, green / 255, blue / 255)[0] * 360
        near_black = maximum < 72
        gray_or_shadow = saturation < 0.10 and maximum < 235
        key_yellow = red > 150 and green > 150 and blue < 90
        key_magenta = red > 150 and blue > 150 and green < 105
        dark_green = green > red * 1.35 and green > blue * 1.35 and maximum < 165
        # The source teal gradient intentionally reaches into bright green.
        # Dark green backing is rejected separately; yellow/orange/red and
        # magenta key spill remain outside this approved range.
        outside_brand_hues = saturation >= 0.10 and not (80 <= hue <= 290)
        if (
            near_black
            or gray_or_shadow
            or key_yellow
            or key_magenta
            or dark_green
            or outside_brand_hues
        ):
            forbidden += 1
            if len(samples) < 5:
                samples.append((red, green, blue, alpha))
    if forbidden:
        raise ContractError(
            f"{relative}: {forbidden} visible pixels violate cyan/purple-only boundary; "
            f"samples={samples}"
        )


def assert_opaque_icon(relative: str, expected_size: tuple[int, int]) -> None:
    with load(relative) as source:
        if source.size != expected_size:
            raise ContractError(f"{relative}: expected {expected_size}, got {source.size}")
        image = source.convert("RGBA")
        if image.getchannel("A").getextrema() != (255, 255):
            raise ContractError(f"{relative}: platform icon must be fully opaque")
        width, height = image.size
        for point in ((0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)):
            pixel = image.getpixel(point)[:3]
            if any(abs(actual - expected) > 2 for actual, expected in zip(pixel, BACKGROUND)):
                raise ContractError(
                    f"{relative}: unexpected corner/background color {pixel}, expected {BACKGROUND}"
                )


def pixel_values(image: Image.Image):
    flattened = getattr(image, "get_flattened_data", None)
    return flattened() if flattened is not None else image.getdata()


def main() -> None:
    assert_transparent_mark(
        "assets/branding/playmesh-mark-master.png",
        validate_geometry=False,
    )
    assert_transparent_mark(
        "assets/branding/playmesh-mark.png",
        (1024, 1024),
        validate_geometry=True,
    )
    assert_transparent_mark(
        "assets/branding/playmesh-logo.png",
        (1024, 1024),
        validate_geometry=True,
    )
    assert_transparent_mark(
        "assets/playmesh-library/public/developer/playmesh-logo.png",
        (256, 256),
        validate_geometry=True,
    )
    assert_transparent_mark("web/icons/Icon-192.png", (192, 192))
    assert_transparent_mark("web/icons/Icon-512.png", (512, 512))
    assert_transparent_mark("web/favicon.png", (32, 32))
    assert_transparent_mark(
        "android/app/src/main/res/drawable-nodpi/ic_launcher_foreground.png",
        (432, 432),
    )

    for density, size in {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }.items():
        assert_opaque_icon(
            f"android/app/src/main/res/mipmap-{density}/ic_launcher.png",
            (size, size),
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
        assert_opaque_icon(
            f"ios/Runner/Assets.xcassets/AppIcon.appiconset/{name}",
            (size, size),
        )

    for size in (16, 32, 64, 128, 256, 512, 1024):
        assert_opaque_icon(
            f"macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png",
            (size, size),
        )

    assert_opaque_icon("web/icons/Icon-maskable-192.png", (192, 192))
    assert_opaque_icon("web/icons/Icon-maskable-512.png", (512, 512))
    assert_opaque_icon(
        "android/app/src/main/res/drawable-nodpi/playmesh_tv_banner.png",
        (320, 180),
    )

    with load("windows/runner/resources/app_icon.ico") as icon:
        rgba = icon.convert("RGBA")
        width, height = rgba.size
        if rgba.getchannel("A").getpixel((0, 0)) != 0:
            raise ContractError("Windows ICO must keep a transparent outer background")
        if width != height or width < 128:
            raise ContractError(f"Windows ICO has an invalid primary frame: {rgba.size}")

    print("Playmesh brand asset contract: OK")


if __name__ == "__main__":
    main()
