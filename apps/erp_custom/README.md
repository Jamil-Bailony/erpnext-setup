# erp_custom

Our Frappe app: every customisation of this ERP goes here, not in a third-party theme
and not as patches in the image build.

## What it does now

- **Fonts** (`erp_custom/public/scss/erp_custom.bundle.scss`): Arabic text uses
  Noto Sans Arabic (body) and Noto Kufi Arabic (headings). Latin text keeps Frappe's Inter.
  The fonts ship with the app (`public/fonts`), so they load on the private network with no
  internet access.

## Adding things

| Change | Where |
|---|---|
| CSS for the desk and website | `public/scss/erp_custom.bundle.scss` (or a new partial imported there) |
| JS for the desk | `public/js/erp_custom.bundle.js` + `app_include_js` in `hooks.py` |
| Custom fields, property setters | `fixtures` in `hooks.py`, exported JSON under `erp_custom/fixtures/` |
| Data fixes on upgrade | `patches.txt` + a module under `erp_custom/patches/` |
| New DocTypes, reports | the `ERP Custom` module (`erp_custom/erp_custom/`) |

Bundles (`*.bundle.*`) are built and content-hashed into the image by `bench build`, so
browsers always get the new file after a deploy. No manual cache-busting needed.
