#!/usr/bin/env python3
"""
Generate test photos with GPS EXIF data + custom DateTimeOriginal for development.

Produces small JPEGs that can be pushed into a simulator's Photos library via
`xcrun simctl addmedia`. Each photo carries the GPS coordinate + creation date the
RememberMe app expects, so they overlay correctly on the day view.
"""

from datetime import datetime
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
import piexif

# Iconic-ish Paris locations spread across the central arrondissements.
PHOTOS = [
    # (filename, latitude, longitude, datetime, title, color)
    ("paris-eiffel.jpg",        48.8584, 2.2945, "2026:05:15 11:23:00", "Eiffel Tower",      (96, 142, 195)),
    ("paris-louvre.jpg",        48.8606, 2.3376, "2026:05:15 14:07:00", "Louvre courtyard",  (190, 144, 91)),
    ("paris-notre-dame.jpg",    48.8530, 2.3499, "2026:05:15 16:42:00", "Île de la Cité",    (130, 168, 122)),
    ("paris-montmartre.jpg",    48.8867, 2.3431, "2026:05:16 10:08:00", "Sacré-Cœur steps",  (231, 207, 178)),
    ("paris-champs.jpg",        48.8738, 2.2950, "2026:05:16 13:54:00", "Champs-Élysées",    (157, 130, 168)),
    ("paris-marais.jpg",        48.8567, 2.3622, "2026:05:16 19:31:00", "Marais evening",    (212, 132, 102)),
]

OUTPUT_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "test-photos"


def deg_to_dms_rational(deg: float):
    """Convert decimal degrees to ((D, 1), (M, 1), (S, 100)) tuple for EXIF."""
    abs_deg = abs(deg)
    degrees = int(abs_deg)
    minutes_full = (abs_deg - degrees) * 60
    minutes = int(minutes_full)
    seconds = round((minutes_full - minutes) * 60 * 100)
    return ((degrees, 1), (minutes, 1), (seconds, 100))


def render_image(path: Path, color, title: str, when: str) -> None:
    image = Image.new("RGB", (640, 480), color)
    draw = ImageDraw.Draw(image)

    # Use the system default font (no need to ship a TTF).
    try:
        font_big = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 36)
        font_small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    except IOError:
        font_big = ImageFont.load_default()
        font_small = ImageFont.load_default()

    # Centered title + date.
    draw.text((40, 200), title, fill="white", font=font_big)
    draw.text((40, 260), when, fill="white", font=font_small)

    image.save(path, "JPEG", quality=85)


def write_exif(path: Path, lat: float, lon: float, when: str) -> None:
    exif = {
        "0th": {
            piexif.ImageIFD.Make: "RememberMe",
            piexif.ImageIFD.Model: "Test fixture",
            piexif.ImageIFD.DateTime: when.encode("ascii"),
        },
        "Exif": {
            piexif.ExifIFD.DateTimeOriginal: when.encode("ascii"),
            piexif.ExifIFD.DateTimeDigitized: when.encode("ascii"),
        },
        "GPS": {
            piexif.GPSIFD.GPSLatitudeRef: ("N" if lat >= 0 else "S").encode("ascii"),
            piexif.GPSIFD.GPSLatitude: deg_to_dms_rational(lat),
            piexif.GPSIFD.GPSLongitudeRef: ("E" if lon >= 0 else "W").encode("ascii"),
            piexif.GPSIFD.GPSLongitude: deg_to_dms_rational(lon),
        },
        "1st": {},
        "thumbnail": None,
    }
    piexif.insert(piexif.dump(exif), str(path))


def main() -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for filename, lat, lon, when, title, color in PHOTOS:
        path = OUTPUT_DIR / filename
        render_image(path, color, title, when)
        write_exif(path, lat, lon, when)
        # Sanity print: confirm EXIF round-trips.
        loaded = piexif.load(str(path))
        original = loaded["Exif"][piexif.ExifIFD.DateTimeOriginal].decode("ascii")
        gps_lat = loaded["GPS"][piexif.GPSIFD.GPSLatitude]
        print(f"wrote {filename}  date={original}  lat≈{gps_lat[0][0]}°{gps_lat[1][0]}'  lon=({lon:.4f})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
