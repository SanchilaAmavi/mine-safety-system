from pathlib import Path
from PIL import Image, ImageDraw

root = Path('.')
icon_dir = root / 'android' / 'app' / 'src' / 'main' / 'res'
mipmap_sizes = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}
web_icons = {
    root / 'web' / 'icons' / 'Icon-192.png': 192,
    root / 'web' / 'icons' / 'Icon-512.png': 512,
}
size = 1024
img = Image.new('RGBA', (size, size), (8, 18, 36, 255))
d = ImageDraw.Draw(img)
# radial gradient background
for i in range(size // 2, 0, -1):
    color = (
        int(10 + (60 * (size//2 - i) / (size//2))),
        int(25 + (90 * (size//2 - i) / (size//2))),
        int(60 + (180 * (size//2 - i) / (size//2))),
        255,
    )
    d.ellipse([size//2-i, size//2-i, size//2+i, size//2+i], fill=color)
# shield shape
shield = [
    (size*0.35, size*0.18),
    (size*0.65, size*0.18),
    (size*0.82, size*0.45),
    (size*0.5, size*0.88),
    (size*0.18, size*0.45),
]
d.polygon(shield, fill=(245, 183, 0, 255))
d.polygon([
    (size*0.37, size*0.24),
    (size*0.63, size*0.24),
    (size*0.76, size*0.45),
    (size*0.5, size*0.82),
    (size*0.24, size*0.45),
], fill=(18, 32, 56, 255))
# S shape
s_path = [
    (size*0.42, size*0.30),
    (size*0.60, size*0.30),
    (size*0.60, size*0.40),
    (size*0.53, size*0.40),
    (size*0.53, size*0.47),
    (size*0.60, size*0.47),
    (size*0.60, size*0.57),
    (size*0.40, size*0.57),
    (size*0.40, size*0.67),
    (size*0.67, size*0.67),
    (size*0.67, size*0.80),
    (size*0.42, size*0.80),
    (size*0.42, size*0.72),
    (size*0.55, size*0.72),
    (size*0.55, size*0.63),
    (size*0.45, size*0.63),
    (size*0.45, size*0.53),
    (size*0.55, size*0.53),
    (size*0.55, size*0.43),
    (size*0.42, size*0.43),
]
d.polygon(s_path, fill=(255, 255, 255, 255))
root.joinpath('assets').mkdir(exist_ok=True)
img.save(root / 'assets' / 'app_icon_base.png')
for folder, sz in mipmap_sizes.items():
    out_dir = icon_dir / folder
    out_dir.mkdir(parents=True, exist_ok=True)
    out = img.resize((sz, sz), Image.LANCZOS)
    out.save(out_dir / 'ic_launcher.png')
for path, sz in web_icons.items():
    path.parent.mkdir(parents=True, exist_ok=True)
    out = img.resize((sz, sz), Image.LANCZOS)
    out.save(path)
(root / 'web' / 'favicon.png').parent.mkdir(parents=True, exist_ok=True)
img.resize((48,48), Image.LANCZOS).save(root / 'web' / 'favicon.png')
print('Generated launcher icon PNGs and web icons.')
