---
name: seo-marketing
description: Put on the SEO/marketing hat for the OnlyTTY site and positioning — clear honest value prop, crawlable server-rendered pages, titles/meta/structured data, internal linking, sitemap, and the /control/:slug long-tail tool pages. Use when editing server/lib/relay_web/site (page.ex, tools.ex), writing positioning/copy, or improving how pages rank and convert.
effort: medium
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# SEO / marketing hat (OnlyTTY)

Sell the wedge honestly and make it findable. OnlyTTY's positioning: **your terminal, on
your phone — end-to-end encrypted, no inbound ports, nothing stored.** Run any command
(Claude, vim, k9s, psql, your whole shell) on your machine and drive it from your phone.
It competes with "just SSH from your phone", screen-share apps, and self-hosted web
terminals — and wins on *can't-read-your-terminal* trust + a 30-second, no-account setup.
The brand is deliberately cheeky (the OnlyFans pun, the toilet bit); **the security is
real.** Sell the joke; never let it undercut the credibility.

## The site already has the machinery — feed it, don't rebuild it

`server/lib/relay_web/site/page.ex` is the whole site as **server-rendered HTML strings**
(no LiveView, no template engine), with `layout/1` emitting the full SEO payload:
canonical, Open Graph, Twitter, and JSON-LD (`WebSite`, `SoftwareApplication`, `FAQPage`,
`BreadcrumbList`). Pages: home, `/tools` (index), **`/control/:slug`** (per-tool),
`/terms`, `/privacy`, `/acceptable-use`, and `/sitemap.xml` (built from the `Tools`
catalog so it can't drift). New tool? Add it to `RelayWeb.Site.Tools` and the page, links,
and sitemap entry generate themselves.

## Hard rule: keep it server-rendered

The pages are unauthenticated, server-rendered HTML — that's the surface crawlers and LLM
bots get. Keep it that way: real content in the initial HTML, nothing injected
client-side, no converting a page to anything JS-dependent. Fast, static-feeling,
dependency-light. (The viewer is `noindex` by design — a tracker there could leak the
fragment secret.)

## The /control/:slug pages are the SEO strategy

Each tool page targets a real query — "control <tool> from your phone", "run <tool>
remotely". That long tail is the growth engine. When adding or expanding tools:
- A unique `<title>` + meta + `<h1>` per tool intent — use the tool's own `why`/`what`
  copy, no boilerplate dupes (thin, near-identical pages hurt the whole catalog).
- Its `SoftwareApplication` + `BreadcrumbList` JSON-LD (already wired via the catalog).
- Internal links to related tools in the same category, and back to how-it-works / FAQ.
- The install + share snippet, so the page converts, not just ranks.

## On-page checklist (per page)

- **One clear `<h1>`** for that page's intent; one page = one topic.
- **Unique `<title>` + meta description**, written for the searcher's intent — the playful
  title still has to say what the thing *is*. Open Graph/Twitter for shareable pages.
- **Structured data** is already emitted; keep it valid after edits
  (`SoftwareApplication`/`FAQPage`/`BreadcrumbList`) and validate it.
- **Internal links** with descriptive anchors between related pages (home → tools →
  control/:slug → how-it-works → FAQ). No orphans. New public page → add it to the sitemap
  and confirm `robots.txt` allows it.
- Headings, alt text, descriptive link text — accessibility and SEO are one checklist.

## Honesty rule (this is a privacy/security product)

**No overclaiming.** "The relay can't read your terminal", "in-memory only", "stores
nothing", "the link is a capability — anyone with it can take control" — the README /
PROTOCOL.md / SECURITY.md are precise, and the marketing must match them *exactly*. The
most valuable asset is that the claims are literally true; one false claim ("zero-trust",
"nobody can ever see it") costs more than it earns. Check security-sensitive copy against
SECURITY.md before shipping it.

## Keywords / intent to target

control/run <tool> from your phone, terminal on your phone, remote terminal without port
forwarding, end-to-end encrypted terminal sharing, share a terminal session read-only,
SSH-from-phone alternative, drive an AI coding agent from your phone. Write for the
developer who wants to watch or steer something on their machine while away from the keys.

## Output

For a page: the `title`/meta/`h1`, the JSON-LD it needs, the internal links to add, and
concrete copy edits in OnlyTTY's voice — not a strategy memo. For positioning: the
one-sentence value prop + three honest proof points (E2E / no inbound ports / stores
nothing), checked against the README.
