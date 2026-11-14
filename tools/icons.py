# Dessine les icônes de Platine (une platine vinyle vue de dessus, « Platine » écrit à la main).
# Usage : python3 tools/icons.py <dossier_sortie> [police_manuscrite]
import sys, os, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 1024
OUT = sys.argv[1] if len(sys.argv) > 1 else "."
FONT = sys.argv[2] if len(sys.argv) > 2 else None
y, x = np.mgrid[0:S, 0:S].astype(np.float32)

def rgb(h): return np.array([int(h[i:i+2], 16) for i in (1, 3, 5)], np.float32) / 255

# nom : (socle haut, socle bas, étiquette du disque, couleur de l'écriture)
THEMES = {
    "main":     ("#f4f4f6", "#cfd0d6", "#ff5c7a", "#151518"),
    "Noir":     ("#2a2a2e", "#0c0c0e", "#ff5c7a", "#f4f4f6"),
    "Rouge":    ("#ff5a5f", "#c81d2a", "#ffffff", "#ffffff"),
    "Orange":   ("#ffb04a", "#f0761a", "#ffffff", "#ffffff"),
    "Jaune":    ("#ffe36b", "#f2b90c", "#ffffff", "#151518"),
    "Vert":     ("#6be38a", "#1f9e4a", "#ffffff", "#ffffff"),
    "Menthe":   ("#8ff0d8", "#2fb8a0", "#ffffff", "#0f3b34"),
    "Bleu":     ("#5fb0ff", "#1e5fe0", "#ffffff", "#ffffff"),
    "Indigo":   ("#8c8aff", "#4b3fd6", "#ffffff", "#ffffff"),
    "Violet":   ("#d69bff", "#8a3fd1", "#ffffff", "#ffffff"),
    "Rose":     ("#ffb3c6", "#ff5c8a", "#ffffff", "#ffffff"),
    "Or":       ("#f7e2a4", "#c9973b", "#fff6dc", "#3a2a08"),
    "Graphite": ("#9a9aa3", "#55555c", "#ff5c7a", "#ffffff"),
}

def disc_layer(cx, cy, R, label):
    img = np.zeros((S, S, 4), np.float32)
    dx, dy = x - cx, y - cy
    r = np.sqrt(dx * dx + dy * dy); a = np.arctan2(dy, dx)
    inside = np.clip(R - r + 0.8, 0, 1)
    vinyl = np.full((S, S, 3), 0.055, np.float32)
    grooves = (np.sin(r * 1.35) * 0.5 + 0.5) * 0.035 * ((r > R * 0.36) & (r < R * 0.97))
    vinyl += grooves[..., None]
    # reflets du vinyle (deux pinceaux de lumière opposés)
    sheen = (np.cos(2 * (a + 0.75)) ** 24) * 0.30 * ((r > R * 0.36) & (r < R * 0.98))
    vinyl += sheen[..., None]
    # étiquette
    lab = np.clip(R * 0.34 - r + 0.8, 0, 1)[..., None]
    vinyl = vinyl * (1 - lab) + label * lab
    ring = np.exp(-((r - R * 0.34) / 1.6) ** 2) * 0.25
    vinyl -= ring[..., None]
    hole = np.clip(R * 0.035 - r + 0.8, 0, 1)[..., None]
    vinyl = vinyl * (1 - hole) + np.array([0.75, 0.75, 0.78]) * hole
    img[..., :3] = np.clip(vinyl, 0, 1); img[..., 3] = inside
    return img

def composite(base, layer):
    a = layer[..., 3:4]
    return base * (1 - a) + layer[..., :3] * a

def make(name, top, bottom, label, ink):
    top, bottom, label, inkc = rgb(top), rgb(bottom), rgb(label), rgb(ink)
    t = ((x + y) / (2 * S))[..., None]
    img = top * (1 - t) + bottom * t
    # léger relief du socle
    img += (np.exp(-((y - S * 0.02) / (S * 0.18)) ** 2) * 0.06)[..., None]
    # plateau (anneau métallique sous le disque)
    cx, cy, R = S * 0.45, S * 0.44, S * 0.345
    r = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    shadow = np.clip(1 - (r - R) / (S * 0.06), 0, 1) * (r > R * 0.9) * 0.35
    img *= (1 - shadow)[..., None]
    plat = np.clip(R * 1.045 - r + 0.8, 0, 1)[..., None]
    metal = 0.62 + 0.25 * np.cos(np.arctan2(y - cy, x - cx) * 2 + 0.6)
    img = img * (1 - plat) + np.stack([metal] * 3, -1) * plat
    img = composite(img, disc_layer(cx, cy, R, label))
    im = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).convert("RGBA")

    # bras de lecture
    arm = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(arm)
    pivot = (S * 0.86, S * 0.15)
    d.ellipse([pivot[0] - 52, pivot[1] - 52, pivot[0] + 52, pivot[1] + 52], fill=(200, 202, 208, 255), outline=(120, 122, 128, 255), width=5)
    d.ellipse([pivot[0] - 22, pivot[1] - 22, pivot[0] + 22, pivot[1] + 22], fill=(90, 92, 98, 255))
    elbow = (S * 0.84, S * 0.55); head = (S * 0.70, S * 0.66)
    d.line([pivot, elbow, head], fill=(226, 228, 232, 255), width=22, joint="curve")
    d.line([pivot, elbow, head], fill=(170, 172, 178, 255), width=6, joint="curve")
    hx, hy = head
    d.rounded_rectangle([hx - 34, hy - 20, hx + 22, hy + 20], radius=8, fill=(40, 40, 44, 255))
    sh = arm.filter(ImageFilter.GaussianBlur(10)); sa = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sa.paste((0, 0, 0, 90), mask=sh.split()[3])
    im.alpha_composite(sa, (10, 14)); im.alpha_composite(arm)

    # « Platine » écrit à la main
    txt = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(txt)
    def load(size):
        for idx in (1, 0):
            try:
                return ImageFont.truetype(FONT, size, index=idx)
            except Exception:
                pass
        return ImageFont.load_default(size=size)
    size = 240
    font = load(size)
    while d.textlength("Platine", font=font) > S * 0.64 and size > 60:
        size -= 6
        font = load(size)
    w = d.textlength("Platine", font=font)
    box = d.textbbox((0, 0), "Platine", font=font)
    tx, ty = S * 0.93 - w, S * 0.95 - box[3]
    col = tuple(int(c * 255) for c in inkc) + (255,)
    d.text((tx, ty), "Platine", font=font, fill=col)
    glow = txt.filter(ImageFilter.GaussianBlur(6)); ga = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ga.paste((0, 0, 0, 70) if sum(inkc) > 1.5 else (255, 255, 255, 60), mask=glow.split()[3])
    im.alpha_composite(ga, (0, 4)); im.alpha_composite(txt)
    out = os.path.join(OUT, "icon.png" if name == "main" else f"icon-{name}.png")
    im.convert("RGB").save(out)

os.makedirs(OUT, exist_ok=True)
for n, c in THEMES.items():
    make(n, *c)
print("icônes :", len(THEMES))
