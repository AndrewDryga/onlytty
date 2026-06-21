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

The served `og.png` (~650 KB) and `icon-512.png` (~210 KB) are heavy for what they are
— see the `(perf/assets) Shrink the heavy served static images` task to optimize them
in place (same dimensions/filenames).

Since the repo isn't published yet, dropping these sources entirely (keeping them in
the design tool / a release artifact) is a legitimate alternative to versioning them
here — they're only originals, not built outputs.
