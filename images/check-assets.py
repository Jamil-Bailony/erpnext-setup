"""Fail the image build if built assets are inconsistent.

Every file named in assets.json / assets-rtl.json must exist on disk, the custom app's
bundles must be in the manifest, and every <app>/locale/<lang>.po must be compiled to
assets/locale/<lang>/LC_MESSAGES/<app>.mo. A miss here means pages load without their
CSS/JS, or translations (e.g. arabic_translations) silently do nothing.

    python3 check-assets.py <sites dir> <custom app>
"""

import json
import pathlib
import sys

sites = pathlib.Path(sys.argv[1])
app = sys.argv[2]
errors = []

for name in ("assets.json", "assets-rtl.json"):
	file = sites / "assets" / name
	if not file.is_file():
		(errors if name == "assets.json" else []).append(f"{name} is missing")
		continue
	manifest = json.loads(file.read_text())
	for key, path in manifest.items():
		if not (sites / path.lstrip("/")).is_file():
			errors.append(f"{name}: {key} -> {path} is missing")
	print(f"{name}: {len(manifest)} entries checked")

manifest = json.loads((sites / "assets" / "assets.json").read_text())
if f"{app}.bundle.css" not in manifest:
	errors.append(f"{app}.bundle.css is not in assets.json")
if not (sites / "assets" / app).exists():
	errors.append(f"assets/{app} (the app's public folder) is missing")

# Translations: the MO files are built into the image like any other asset.
apps = (sites / "apps.txt").read_text().split()
for a in apps:
	for po in (sites.parent / "apps" / a / a / "locale").glob("*.po"):
		mo = sites / "assets" / "locale" / po.stem / "LC_MESSAGES" / f"{a}.mo"
		if not mo.is_file():
			errors.append(f"{po.relative_to(sites.parent)} is not compiled ({mo.relative_to(sites)})")
		elif po.stem == "ar":
			print(f"{a}: ar.mo {mo.stat().st_size} bytes")

if errors:
	print("\n".join(errors), file=sys.stderr)
	sys.exit(1)
print("assets OK")
