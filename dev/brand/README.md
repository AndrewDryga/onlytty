# Brand design sources

Raw design **originals** for OnlyTTY — kept out of the deployable app (they used to
sit inside the Elixir release as ~5 MB of unreferenced PNGs). Nothing in the build
consumes these; the app serves separately-exported, optimized assets under
`portal/priv/static/`. Edit a source here, then re-export the served
asset(s) it maps to below.

## Source → served asset

The exports were done by hand (no scripted pipeline), so exact tool/settings aren't
recorded — re-export at the target dimensions below, then optimize the PNG
(e.g. `oxipng`/`pngquant`) before committing it to `priv/static`.

| Source (this dir) | Served asset(s) | Used for |
|-------------------|-----------------|----------|
| `app-icon.png` | `priv/static/assets/icon-192.png` (192×192), `icon-512.png` (512×512), `apple-touch-icon.png` (180×180), `priv/static/favicon.ico` | PWA manifest icons, iOS home-screen icon, favicon |
| `banner.png` | `priv/static/assets/og.png` (1200×630) | Open Graph / social link preview |
| `mascot-color.png` | `priv/static/assets/brand/mascot.png` | the mascot shown on the site |
| `mascot-mono.png` | — | monochrome mascot variant; not currently served |
| `logo-lockup-light.png` | — | wordmark/lockup for external use (READMEs, decks); not currently served |

The served PNGs are optimized in place (same dimensions/filenames) with **pngquant**
(`--quality=80-96 --strip`) then **oxipng** (`-o6`) — near-lossless, no visible quality
loss. Re-run that pair after re-exporting any served PNG. Current sizes: og.png ~39 KB,
icon-512 ~25 KB, icon-192 ~6 KB, apple-touch ~5 KB, mascot ~15 KB.

NOTE: `og.png` still shows a stale `$ relay -- claude` snippet — it needs re-exporting
from `banner.png` with the `onlytty` command (a content change, not an optimization).

Since the repo isn't published yet, dropping these sources entirely (keeping them in
the design tool / a release artifact) is a legitimate alternative to versioning them
here — they're only originals, not built outputs.
