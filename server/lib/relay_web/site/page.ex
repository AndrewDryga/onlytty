defmodule RelayWeb.Site.Page do
  @moduledoc """
  Server-rendered marketing pages for OnlyTTY.

  Pages are plain HTML strings — no template engine, no `phoenix_html`/LiveView
  dependency — matching the dependency-light spirit of the rest of the project
  (the viewer is hand-written too). `layout/1` wraps every page in one head/nav/
  footer shell with the full SEO payload (canonical, Open Graph, Twitter, JSON-LD).

  All interpolated text flows through `h/1` (HTML-escaped). Tool slugs are looked
  up in `RelayWeb.Site.Tools` and never echoed from raw request input, so the only
  dynamic values that reach a page are from our own catalog.
  """

  alias RelayWeb.Site.Tools

  @github "https://github.com/AndrewDryga/relay"
  @og_image "/assets/og.png"

  # ── Public page builders ──────────────────────────────────────────────────

  @doc "The home page."
  def home do
    layout(
      title: "OnlyTTY — your terminal, on your phone (yes, even on the toilet)",
      description:
        "Run any command on your machine and drive it from your phone — Claude, Vim, k9s, psql, your whole shell. End-to-end encrypted, no inbound ports, nothing stored.",
      path: "/",
      json_ld: [website_ld(), software_ld(), faq_ld()],
      body:
        hero() <>
          trust_bar() <>
          how_section() <>
          features_section() <>
          home_tools() <>
          testimonials() <> faq_section() <> brand_band() <> start_section()
    )
  end

  @doc "A per-tool landing page. `tool` is a catalog map from `Tools`."
  def tool(tool) do
    layout(
      title: "Control #{tool.name} from your phone · OnlyTTY",
      description:
        "Run #{tool.name} on your machine and drive it from your phone with OnlyTTY. #{tool.why} End-to-end encrypted, read-only by default, nothing stored.",
      path: "/control/#{tool.slug}",
      json_ld: [tool_software_ld(tool), breadcrumb_ld(tool)],
      body: tool_body(tool)
    )
  end

  @doc "The full, browse-by-category tool index."
  def tools_index do
    layout(
      title: "Every CLI you can drive from your phone · OnlyTTY",
      description:
        "OnlyTTY works with any terminal command. Browse #{length(Tools.all())} ready-made guides — AI agents, editors, multiplexers, databases, ops TUIs and more.",
      path: "/tools",
      json_ld: [breadcrumb_simple_ld("Tools", "/tools")],
      body: tools_index_body()
    )
  end

  @doc "The branded 404 body (the controller sets the 404 status)."
  def not_found do
    layout(
      title: "Lost the connection · OnlyTTY",
      description: "That page expired or never existed.",
      path: "/404",
      noindex: true,
      json_ld: [],
      body: """
      <section class="wrap section center">
        <img class="brand-mascot" src="/assets/brand/mascot.png" width="120" height="151" alt="OnlyTTY mascot">
        <p class="eyebrow">404 · session not found</p>
        <h1>This link points to nothing.</h1>
        <p class="lede">Like a session that's already expired. No bytes here — just a dead cursor.</p>
        <div class="cta-row center"><a class="btn btn-primary" href="/">Back home</a><a class="btn btn-ghost" href="/tools">Browse tools</a></div>
      </section>
      """
    )
  end

  @doc "Terms of Service."
  def terms do
    legal_page("Terms of Service", "/terms", """
    <p class="lede">OnlyTTY is a relay that pairs a command running on your machine with a browser, forwarding <strong>end-to-end-encrypted</strong> terminal frames between them. The relay never sees your terminal content — it forwards ciphertext and stores nothing.</p>
    <h2>The link is a capability</h2>
    <p>Each session is reached by a link whose <code>#fragment</code> holds the secret. Anyone with the full link is a viewer, and — unless you started the session read-only — can take control and type into it. Treat the link like a password: share it deliberately, use <code>--read-only</code> or <code>--passphrase</code> when you need to, and stop sharing by exiting the command.</p>
    <h2>No accounts, ephemeral sessions</h2>
    <p>There are no accounts. Sessions live in memory only and expire (by default within hours, capped at 24h); when a session ends, it is gone.</p>
    <h2>Acceptable use</h2>
    <p>Your use must follow the <a href="/acceptable-use">Acceptable Use Policy</a>. We may drop sessions or block traffic that abuses the service.</p>
    <h2>No warranty</h2>
    <p>OnlyTTY is provided “as is”, without warranty of any kind. You use it at your own risk, and to the extent permitted by law we are not liable for any damages arising from its use. If you self-host the open-source relay, you operate it under its license.</p>
    """)
  end

  @doc "Privacy Policy."
  def privacy do
    legal_page("Privacy Policy", "/privacy", """
    <p class="lede">The short version: the relay can’t read your terminal, keeps sessions in memory only, and logs almost nothing.</p>
    <h2>What we cannot see</h2>
    <p>Terminal input and output are end-to-end encrypted under keys derived from a secret that lives only in the link’s fragment — which browsers never send to the server. The relay forwards opaque ciphertext; it cannot read or reconstruct your session.</p>
    <h2>What exists, and only in memory</h2>
    <p>While a session is live the relay holds its id, a runner token, and an expiry — in RAM only. Nothing session-related is written to a database or disk, and it is discarded when the session ends or expires.</p>
    <h2>What we log</h2>
    <p>Operational logs carry metadata only: an 8-character session-id prefix, the role (runner or viewer), and a timestamp. We do <strong>not</strong> log IP addresses or any terminal content.</p>
    <h2>No tracking</h2>
    <p>No accounts, no advertising, and no third-party analytics or tracking beacons — on this site or in the viewer (a browser tracker could leak the fragment secret, so there is none).</p>
    <h2>Contact</h2>
    <p>Privacy questions: <a href="mailto:andrew@dryga.com">andrew@dryga.com</a>.</p>
    """)
  end

  @doc "Acceptable Use Policy."
  def acceptable_use do
    legal_page("Acceptable Use Policy", "/acceptable-use", """
    <p class="lede">OnlyTTY shares your own terminal. Don’t use it to harm others or to break the law.</p>
    <h2>Don’t</h2>
    <ul>
      <li>Use the service for anything illegal, or to facilitate illegal activity.</li>
      <li>Use the relay as a covert tunnel, to evade network controls, or to disguise the origin of traffic.</li>
      <li>Attack, overload, or attempt to compromise the relay, its infrastructure, or other users’ sessions.</li>
      <li>Share a link with someone you don’t intend to give terminal access — the link is a capability.</li>
    </ul>
    <h2>Enforcement</h2>
    <p>Sessions are end-to-end encrypted, so we can’t police their contents — but we can and will drop sessions and block traffic that abuses the service or its infrastructure.</p>
    <h2>Report abuse</h2>
    <p>Email <a href="mailto:andrew@dryga.com">andrew@dryga.com</a> with details. For security vulnerabilities, see <a href="https://github.com/AndrewDryga/relay/blob/main/SECURITY.md">SECURITY.md</a>.</p>
    """)
  end

  @doc """
  The XML sitemap, built from the tool catalog so it can never drift from the
  pages that actually exist.
  """
  def sitemap do
    urls =
      [
        {"/", "1.0"},
        {"/tools", "0.8"},
        {"/terms", "0.3"},
        {"/privacy", "0.3"},
        {"/acceptable-use", "0.3"}
      ] ++
        Enum.map(Tools.all(), &{"/control/#{&1.slug}", "0.6"})

    entries =
      Enum.map_join(urls, "\n", fn {path, priority} ->
        "  <url><loc>#{base_url()}#{path}</loc><priority>#{priority}</priority></url>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{entries}
    </urlset>
    """
  end

  # ── Layout shell ──────────────────────────────────────────────────────────

  defp layout(opts) do
    title = Keyword.fetch!(opts, :title)
    desc = Keyword.fetch!(opts, :description)
    path = Keyword.fetch!(opts, :path)
    body = Keyword.fetch!(opts, :body)
    json_ld = Keyword.get(opts, :json_ld, [])
    robots = if(Keyword.get(opts, :noindex, false), do: "noindex,follow", else: "index,follow")
    url = base_url() <> path
    img = base_url() <> @og_image

    ld_tags =
      Enum.map_join(json_ld, "\n", fn data ->
        ~s(<script type="application/ld+json">#{Jason.encode!(data)}</script>)
      end)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>#{h(title)}</title>
    <meta name="description" content="#{h(desc)}">
    <link rel="canonical" href="#{h(url)}">
    <meta name="robots" content="#{robots}">
    <meta name="theme-color" content="#0a0b10">
    <meta name="color-scheme" content="dark">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="OnlyTTY">
    <meta property="og:title" content="#{h(title)}">
    <meta property="og:description" content="#{h(desc)}">
    <meta property="og:url" content="#{h(url)}">
    <meta property="og:image" content="#{h(img)}">
    <meta property="og:image:width" content="1200">
    <meta property="og:image:height" content="630">
    <meta name="twitter:card" content="summary_large_image">
    <meta name="twitter:title" content="#{h(title)}">
    <meta name="twitter:description" content="#{h(desc)}">
    <meta name="twitter:image" content="#{h(img)}">
    <link rel="icon" href="/favicon.ico" sizes="any">
    <link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
    <link rel="manifest" href="/assets/site.webmanifest">
    <link rel="stylesheet" href="/assets/site.css">
    #{ld_tags}
    </head>
    <body>
    #{nav()}
    <main>#{body}</main>
    #{footer()}
    #{script()}
    </body>
    </html>
    """
  end

  defp nav do
    """
    <a class="skip" href="#main">Skip to content</a>
    <header class="nav">
      <div class="wrap nav-inner">
        <a class="brand" href="/" aria-label="OnlyTTY home">#{logo()}<span>Only<b>TTY</b></span></a>
        <nav class="nav-links" aria-label="Primary">
          <a href="/#how">How it works</a>
          <a href="/tools">Tools</a>
          <a href="/#faq">FAQ</a>
          <a href="#{@github}" rel="noopener">GitHub</a>
        </nav>
        <a class="btn btn-primary btn-sm" href="/#start">Get started</a>
      </div>
    </header>
    <span id="main"></span>
    """
  end

  defp footer do
    """
    <footer class="footer">
      <div class="wrap footer-grid">
        <div class="footer-brand">
          <a class="brand" href="/">#{logo()}<span>Only<b>TTY</b></span></a>
          <p>Your terminal, on your phone. End-to-end encrypted, so the server in the middle only ever sees ciphertext.</p>
        </div>
        <nav aria-label="Product">
          <h3>Product</h3>
          <a href="/#how">How it works</a>
          <a href="/tools">Supported tools</a>
          <a href="/#start">Get started</a>
          <a href="/#faq">FAQ</a>
        </nav>
        <nav aria-label="Trust">
          <h3>Trust &amp; security</h3>
          <a href="#{@github}/blob/main/PROTOCOL.md" rel="noopener">Protocol</a>
          <a href="#{@github}/blob/main/SECURITY.md" rel="noopener">Security model</a>
          <a href="#{@github}" rel="noopener">Source on GitHub</a>
        </nav>
        <nav aria-label="Legal">
          <h3>Legal</h3>
          <a href="/terms">Terms</a>
          <a href="/privacy">Privacy</a>
          <a href="/acceptable-use">Acceptable use</a>
          <a href="/sitemap.xml">Sitemap</a>
        </nav>
      </div>
      <div class="wrap footer-bottom">
        <span>© OnlyTTY · open source</span>
        <span>Made by <a href="https://dryga.com" rel="noopener">Andrew Dryga</a></span>
      </div>
    </footer>
    """
  end

  # ── Home sections ─────────────────────────────────────────────────────────

  defp hero do
    rotate = Jason.encode!(["claude", "codex", "aider", "gemini", "psql"])

    """
    <section class="hero">
      <div class="wrap hero-grid">
        <div class="hero-copy">
          <h1>Want to control your <span class="hl" data-rotate='#{rotate}'>claude</span> while sitting on the toilet?</h1>
          <p class="lede">OnlyTTY gives any command on your machine a private link you can drive from your phone — end-to-end encrypted, so the relay only ever sees ciphertext.</p>
          <div class="cta-row">
            <a class="btn btn-primary" href="#start">Get started — it's free</a>
            <a class="btn btn-ghost" href="#how">See how it works</a>
          </div>
        </div>
        <div class="hero-demo">#{term_demo()}</div>
      </div>
    </section>
    """
  end

  defp trust_bar do
    """
    <section class="trust">
      <div class="wrap trust-inner">
        <span>#{icon("check")} End-to-end encrypted</span>
        <span>#{icon("check")} No inbound ports</span>
        <span>#{icon("check")} Survives bad Wi-Fi</span>
        <span>#{icon("check")} Open source</span>
      </div>
    </section>
    """
  end

  defp how_section do
    """
    <section id="how" class="section">
      <div class="wrap">
        <p class="eyebrow center">How it works</p>
        <h2 class="center">Three steps. No port forwarding, no agents, no accounts.</h2>
        <div class="steps">
          #{step("1", "Run it", "<code>relay -- claude</code> — or just <code>relay</code> to share your whole shell. It keeps running in your terminal and prints a link plus a QR code.")}
          #{step("2", "Scan it", "Open the link on your phone. The session secret rides in the URL <code>#fragment</code>, which never leaves the browser — so the relay can't read a thing.")}
          #{step("3", "Drive it", "Watch live, or tap <em>take control</em> to type — anyone with the link can, so share it like a key (or start <code>--read-only</code>). Lose signal? It reconnects and picks up where you left off.")}
        </div>
      </div>
    </section>
    """
  end

  defp features_section do
    """
    <section class="section alt">
      <div class="wrap">
        <p class="eyebrow center">Security &amp; trust</p>
        <h2 class="center">A remote terminal you don't have to be nervous about.</h2>
        <div class="features">
          #{feature("lock", "End-to-end encrypted", "Keys come from a secret in the link's fragment that the relay never receives. It forwards ciphertext; your keystrokes stay yours.")}
          #{feature("wifi", "Survives bad Wi-Fi", "Long-lived sessions that ride out dropouts, sleep, and dead zones. Lose signal on the subway, resurface, and your terminal is right where you left it.")}
          #{feature("key", "The link is the key", "Anyone with the full link can watch and take control — read-only is just the default view. Start it read-only to lock that down, or add a passphrase the link alone can't decrypt.")}
          #{feature("shield", "No inbound ports", "The CLI dials out over TLS. Nothing listens on your machine, so your firewall stays exactly as shut as it is now.")}
          #{feature("terminal", "Works with any CLI", "If it runs in a terminal, OnlyTTY shares it. Agents, editors, REPLs, TUIs — or your whole shell.")}
          #{feature("trash", "Stores nothing", "The relay pairs two encrypted sockets and forgets you exist. No accounts, no history, no logs of your bytes.")}
        </div>
      </div>
    </section>
    """
  end

  defp home_tools do
    chips = Enum.map_join(Tools.featured(), "", &chip/1)

    """
    <section id="tools" class="section">
      <div class="wrap">
        <p class="eyebrow center">Compatibility</p>
        <h2 class="center">Pick your poison. There's a guide for each.</h2>
        <div class="chips">#{chips}</div>
        <p class="center more"><a class="btn btn-ghost" href="/tools">Browse all #{length(Tools.all())} tools →</a></p>
      </div>
    </section>
    """
  end

  defp testimonials do
    """
    <section class="section alt">
      <div class="wrap">
        <p class="eyebrow center">Testimonials</p>
        <h2 class="center">The only fanbase your terminal will ever need.</h2>
        <div class="quotes">
          #{quote_card("My subscribers can't get enough of my uptime. It's just me. I am the subscriber.", "rootdaddy", "self-hosted everything")}
          #{quote_card("I approved a deploy from a moving train. My on-call lead wept with joy.", "kubehoncho", "reluctant SRE")}
          #{quote_card("Finally monetized my dotfiles. Spiritually. Emotionally. Not financially.", "vimgod", "still can't exit")}
        </div>
        <p class="center disclaimer">Testimonials are dramatizations. The encryption is not.</p>
      </div>
    </section>
    """
  end

  defp faq_section do
    items = Enum.map_join(faqs(), "", fn {q, a} -> faq_item(q, a) end)

    """
    <section id="faq" class="section">
      <div class="wrap narrow">
        <p class="eyebrow center">FAQ</p>
        <h2 class="center">Questions you're right to ask</h2>
        <div class="faq">#{items}</div>
      </div>
    </section>
    """
  end

  defp brand_band do
    """
    <section class="section brand-band">
      <div class="wrap center">
        <img class="banner" src="/assets/brand/banner.png" width="1200" height="580" loading="lazy"
             alt="OnlyTTY — control your CLI from anywhere">
      </div>
    </section>
    """
  end

  defp start_section do
    """
    <section id="start" class="section start">
      <div class="wrap narrow center">
        <p class="eyebrow center">Get started</p>
        <h2 class="center">Your terminal is about to go public. To exactly one fan: you.</h2>
        <p class="lede center">Install the open-source CLI, then share a command — or your whole shell. It prints a link and a QR; scan it and you're live.</p>
        <div class="start-card">
          <div class="examples">
            #{example_row("Install", "go install github.com/AndrewDryga/relay@latest")}
            #{example_row("Your whole shell", "relay")}
            #{example_row("One command", "relay -- claude")}
            #{example_row("Watch-only", "relay --read-only -- htop")}
          </div>
        </div>
        <div class="cta-row center"><a class="btn btn-primary" href="#{@github}" rel="noopener">Get the CLI on GitHub</a><a class="btn btn-ghost" href="/tools">See what you can control</a></div>
      </div>
    </section>
    """
  end

  defp example_row(label, cmd) do
    ~s(<div class="example"><span class="example-label">#{h(label)}</span>#{snippet(cmd)}</div>)
  end

  # ── Tool page ─────────────────────────────────────────────────────────────

  defp tool_body(t) do
    related =
      Tools.all()
      |> Enum.filter(&(&1.category == t.category and &1.slug != t.slug))
      |> Enum.take(6)

    related_html =
      case related do
        [] ->
          ""

        rs ->
          """
          <section class="section">
            <div class="wrap">
              <h2 class="center">More #{h(String.downcase(t.category))} to run from the loo</h2>
              <div class="chips">#{Enum.map_join(rs, "", &chip/1)}</div>
              <p class="center more"><a class="btn btn-ghost" href="/tools">Browse all tools →</a></p>
            </div>
          </section>
          """
      end

    """
    <section class="hero tool-hero">
      <div class="wrap">
        <nav class="crumbs" aria-label="Breadcrumb"><a href="/">Home</a> <span aria-hidden="true">›</span> <a href="/tools">Tools</a> <span aria-hidden="true">›</span> <span>#{h(t.name)}</span></nav>
        <p class="eyebrow">#{h(t.category)}</p>
        <h1>Want to control <span class="hl">#{h(t.name)}</span> while sitting on the toilet?</h1>
        <p class="lede">#{h(t.why)}</p>
        #{snippet("relay -- #{t.cmd}")}
        <div class="cta-row"><a class="btn btn-primary" href="#start">Get started — it's free</a><a class="btn btn-ghost" href="/tools">Browse all tools</a></div>
      </div>
    </section>

    <section class="section alt">
      <div class="wrap narrow">
        <h2>So… what is this?</h2>
        <p class="lede">#{h(t.name)} is #{h(lead_phrase(t.what))} OnlyTTY runs it on your own machine, wraps it in a PTY, and gives you a private, end-to-end-encrypted link to drive it from your phone. The terminal stays live where you launched it; your phone just becomes a second screen and keyboard for the same session.</p>
        <p>It's read-only by default, so a shared link can only watch until you tap <em>take control</em>. The session secret never reaches the server — it lives in the link's <code>#fragment</code> — so the relay forwarding your bytes only ever sees ciphertext. When the session expires, it's gone. Nothing is stored.</p>
      </div>
    </section>

    #{how_section()}
    #{features_section()}
    #{related_html}
    #{start_section()}
    """
  end

  # ── Tools index ───────────────────────────────────────────────────────────

  defp tools_index_body do
    sections =
      Enum.map_join(Tools.by_category(), "", fn {cat, tools} ->
        cards = Enum.map_join(tools, "", &tool_card/1)

        """
        <section class="section">
          <div class="wrap">
            <h2 id="#{h(slugify(cat))}">#{h(cat)}</h2>
            <div class="cards">#{cards}</div>
          </div>
        </section>
        """
      end)

    """
    <section class="hero">
      <div class="wrap">
        <p class="eyebrow">#{length(Tools.all())} ready-made guides</p>
        <h1>If it runs in a terminal, you can run it from the toilet.</h1>
        <p class="lede">OnlyTTY works with any command — these just have a page already. Pick one, copy the snippet, scan the link.</p>
        <div class="cta-row"><a class="btn btn-primary" href="/#start">Get started — it's free</a></div>
      </div>
    </section>
    #{sections}
    #{start_section()}
    """
  end

  # ── Legal ─────────────────────────────────────────────────────────────────

  # `body` is trusted literal markup (headings/lists/links), so it is not escaped.
  defp legal_page(title, path, body) do
    layout(
      title: "#{title} · OnlyTTY",
      description:
        "OnlyTTY #{title} — written honestly to the architecture: end-to-end encrypted, in-memory sessions, minimal logging.",
      path: path,
      json_ld: [breadcrumb_simple_ld(title, path)],
      body: """
      <article class="section">
        <div class="wrap narrow legal">
          <nav class="crumbs" aria-label="Breadcrumb"><a href="/">Home</a> <span aria-hidden="true">›</span> <span>#{h(title)}</span></nav>
          <h1>#{h(title)}</h1>
          #{body}
          <p class="muted">This is a plain-language summary, not formal legal advice; a service operator should have it reviewed before launch.</p>
        </div>
      </article>
      """
    )
  end

  # ── Small components ──────────────────────────────────────────────────────

  defp chip(t) do
    ~s(<a class="chip" href="/control/#{h(t.slug)}"><b>#{h(t.name)}</b><code>relay -- #{h(t.cmd)}</code></a>)
  end

  defp tool_card(t) do
    """
    <a class="card" href="/control/#{h(t.slug)}">
      <span class="card-name">#{h(t.name)}</span>
      <span class="card-what">#{h(t.what)}</span>
      <code class="card-cmd">relay -- #{h(t.cmd)}</code>
    </a>
    """
  end

  defp feature(icon_name, title, body) do
    ~s(<div class="feature"><span class="feature-icon" aria-hidden="true">#{icon(icon_name)}</span><h3>#{h(title)}</h3><p>#{h(body)}</p></div>)
  end

  # Crisp inline icons (Lucide-style, 24px stroke, currentColor) — consistent and
  # platform-independent, unlike emoji.
  defp icon(name) do
    paths =
      case name do
        "check" ->
          ~s(<path d="M20 6 9 17l-5-5"/>)

        "lock" ->
          ~s(<rect width="18" height="11" x="3" y="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>)

        "wifi" ->
          ~s(<path d="M5 13a10 10 0 0 1 14 0"/><path d="M8.5 16.5a5 5 0 0 1 7 0"/><path d="M2 8.8a15 15 0 0 1 20 0"/><line x1="12" x2="12.01" y1="20" y2="20"/>)

        "key" ->
          ~s(<circle cx="7.5" cy="15.5" r="5.5"/><path d="m21 2-9.6 9.6"/><path d="m15.5 7.5 3 3L22 7l-3-3"/>)

        "shield" ->
          ~s(<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/>)

        "terminal" ->
          ~s(<polyline points="4 17 10 11 4 5"/><line x1="12" x2="20" y1="19" y2="19"/>)

        "trash" ->
          ~s(<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>)
      end

    ~s(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{paths}</svg>)
  end

  defp step(n, title, body) do
    # `body` here is trusted literal markup (contains <code>/<em>), so it is not escaped.
    ~s(<div class="step"><span class="num">#{n}</span><h3>#{h(title)}</h3><p>#{body}</p></div>)
  end

  defp quote_card(text, handle, role) do
    """
    <figure class="quote">
      <blockquote>#{h(text)}</blockquote>
      <figcaption><b>@#{h(handle)}</b><span>#{h(role)}</span></figcaption>
    </figure>
    """
  end

  defp faq_item(q, a) do
    # `a` is trusted literal markup (may contain links/code), so it is not escaped.
    "<details class=\"faq-item\"><summary>#{h(q)}</summary><div class=\"faq-a\">#{a}</div></details>"
  end

  defp snippet(text) do
    ~s(<div class="snippet"><code><span class="prompt">$</span> #{h(text)}</code><button class="copy" type="button" data-copy="#{h(text)}" aria-label="Copy command">Copy</button></div>)
  end

  defp term_demo do
    # Built with explicit newlines (not a heredoc) because <pre> is
    # whitespace-sensitive and heredoc indentation rules would fight the layout.
    # Mirrors the real `relay` banner (see printBanner in main.go): the bold title,
    # the QR, then aligned Link / Fingerprint / Expires / Control rows and the note.
    body =
      Enum.join(
        [
          ~s(<span class="c-p">$</span> relay -- claude),
          "",
          ~s(  <span class="c-b">relay — this session is shared, end-to-end encrypted</span>),
          "",
          "  " <> qr(),
          ~s(  Link         <span class="c-link">https://onlytty.com/s/k7p2qx</span><span class="c-frag">#9f3q4d…</span>),
          ~s|  Fingerprint  K7Q2-9FW3-PXM4-RT8A  <span class="c-dim">(must match in the browser)</span>|,
          ~s(  Expires      in 12h0m0s),
          ~s(  Control      viewers may request control),
          "",
          ~s(  <span class="c-dim">Scan the QR or open the link. The relay only ever sees ciphertext.</span>),
          ~s(<span class="c-p">$</span> <span class="cursor">█</span>)
        ],
        "\n"
      )

    ~s(<div class="term" role="img" aria-label="Terminal showing the relay command printing a share link, QR code and fingerprint for an end-to-end-encrypted session">) <>
      ~s(<div class="term-bar"><span class="tdot r"></span><span class="tdot y"></span><span class="tdot g"></span><span class="term-title">zsh — onlytty</span></div>) <>
      ~s(<pre class="term-body">) <> body <> ~s(</pre></div>)
  end

  # A decorative (non-scannable) QR-style mark for the demo. aria-hidden.
  defp qr do
    finder = fn x, y ->
      ~s(<rect x="#{x}" y="#{y}" width="22" height="22" rx="3" fill="#0a0b10"/>) <>
        ~s(<rect x="#{x + 4}" y="#{y + 4}" width="14" height="14" rx="2" fill="#fff"/>) <>
        ~s(<rect x="#{x + 8}" y="#{y + 8}" width="6" height="6" rx="1" fill="#0a0b10"/>)
    end

    dots =
      [
        {36, 8},
        {44, 16},
        {36, 24},
        {52, 24},
        {62, 36},
        {36, 44},
        {44, 44},
        {52, 52},
        {36, 60},
        {44, 68},
        {62, 60},
        {68, 44},
        {28, 36},
        {8, 36},
        {16, 44}
      ]
      |> Enum.map_join("", fn {x, y} ->
        ~s(<rect x="#{x}" y="#{y}" width="6" height="6" rx="1" fill="#0a0b10"/>)
      end)

    ~s(<svg class="qr" viewBox="0 0 80 80" aria-hidden="true"><rect width="80" height="80" rx="8" fill="#fff"/>) <>
      finder.(6, 6) <> finder.(52, 6) <> finder.(6, 52) <> dots <> ~s(</svg>)
  end

  defp logo do
    ~s(<img class="logo" src="/assets/brand/mascot.png" width="24" height="30" alt="" aria-hidden="true">)
  end

  defp script do
    """
    <script>
    (function () {
      var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
      var el = document.querySelector('[data-rotate]');
      if (el && !reduce) {
        try {
          var words = JSON.parse(el.getAttribute('data-rotate')), i = 0;
          setInterval(function () { i = (i + 1) % words.length; el.textContent = words[i]; }, 2200);
        } catch (e) {}
      }
      document.querySelectorAll('[data-copy]').forEach(function (b) {
        b.addEventListener('click', function () {
          var text = b.getAttribute('data-copy');
          if (!navigator.clipboard) return;
          navigator.clipboard.writeText(text).then(function () {
            var prev = b.textContent;
            b.textContent = 'Copied';
            setTimeout(function () { b.textContent = prev; }, 1200);
          });
        });
      });
    })();
    </script>
    """
  end

  # ── Content data ──────────────────────────────────────────────────────────

  defp faqs do
    [
      {"Is this an OnlyFans thing?",
       "No. OnlyTTY is a developer tool with a cheeky name. The only content here is your own terminal, and the only subscriber is you. The joke is the branding; the end-to-end encryption is completely real."},
      {"Can the server see my terminal?",
       ~s(No. The session secret lives in the link's <code>#fragment</code>, which browsers never send to the server. Keys are derived from it, so the relay only ever forwards ciphertext. Read the <a href="#{@github}/blob/main/PROTOCOL.md" rel="noopener">protocol</a> and <a href="#{@github}/blob/main/SECURITY.md" rel="noopener">security model</a> yourself.)},
      {"Do I have to open a port or install an agent?",
       "No inbound ports and no daemon. The <code>relay</code> CLI dials out over WebSocket/TLS, so nothing listens on your machine. It's a single Go binary."},
      {"Who can take control of my session?",
       ~s(Anyone with the full link. The link is the key: whoever opens it can watch — and can tap <em>take control</em> to type. Read-only is just the default view, not a per-person gate, so share the link like a password. Want watch-only? Start with <code>--read-only</code>. Want a second factor? Add <code>--passphrase</code>, and the link alone won't decrypt. Either way, exit the command to stop sharing instantly.)},
      {"What can I actually control?",
       ~s(Anything that runs in a terminal: AI coding agents, editors, REPLs, database shells, ops TUIs, or your whole <code>\$SHELL</code>. Browse the <a href="/tools">full list</a> for ready-made guides.)},
      {"Is it really free and open source?",
       ~s(Yes. The relay server and the CLI are open source — host your own relay or audit the code on <a href="#{@github}" rel="noopener">GitHub</a>. No accounts, no tracking.)},
      {"How long does a session last, and what if my connection drops?",
       ~s(As long as you want it to. Sessions are long-lived and resilient — they ride out flaky networks, sleep, and dead zones, reconnecting on their own so you can drop off Wi-Fi and pick right back up. Set the lifetime with <code>--ttl</code>, up to a day. When you exit the command or it expires, it's gone — the relay stores nothing.)},
      {"Okay, but the toilet thing?",
       "We're simply acknowledging that the bathroom is now a valid on-call location. Approve the deploy, kill the runaway process, answer your agent's question — then wash your hands. You're welcome."}
    ]
  end

  # ── JSON-LD ───────────────────────────────────────────────────────────────

  defp website_ld do
    %{
      "@context" => "https://schema.org",
      "@type" => "WebSite",
      "name" => "OnlyTTY",
      "url" => base_url() <> "/",
      "description" =>
        "Run any command on your machine and drive it from your phone — end-to-end encrypted."
    }
  end

  defp software_ld do
    %{
      "@context" => "https://schema.org",
      "@type" => "SoftwareApplication",
      "name" => "OnlyTTY",
      "applicationCategory" => "DeveloperApplication",
      "operatingSystem" => "macOS, Linux, Windows",
      "url" => base_url() <> "/",
      "description" =>
        "OnlyTTY wraps any terminal command on your machine and gives you an end-to-end-encrypted link to drive it from your phone.",
      "offers" => %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD"},
      "isAccessibleForFree" => true
    }
  end

  defp tool_software_ld(t) do
    %{
      "@context" => "https://schema.org",
      "@type" => "SoftwareApplication",
      "name" => "OnlyTTY for #{t.name}",
      "applicationCategory" => "DeveloperApplication",
      "operatingSystem" => "macOS, Linux, Windows",
      "url" => base_url() <> "/control/#{t.slug}",
      "description" =>
        "Run #{t.name} on your machine and drive it from your phone with OnlyTTY. #{t.why}",
      "offers" => %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD"},
      "isAccessibleForFree" => true
    }
  end

  defp faq_ld do
    %{
      "@context" => "https://schema.org",
      "@type" => "FAQPage",
      "mainEntity" =>
        Enum.map(faqs(), fn {q, a} ->
          %{
            "@type" => "Question",
            "name" => q,
            "acceptedAnswer" => %{"@type" => "Answer", "text" => strip_tags(a)}
          }
        end)
    }
  end

  defp breadcrumb_ld(t) do
    breadcrumb([{"Home", "/"}, {"Tools", "/tools"}, {t.name, "/control/#{t.slug}"}])
  end

  defp breadcrumb_simple_ld(name, path) do
    breadcrumb([{"Home", "/"}, {name, path}])
  end

  defp breadcrumb(items) do
    %{
      "@context" => "https://schema.org",
      "@type" => "BreadcrumbList",
      "itemListElement" =>
        items
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, path}, i} ->
          %{"@type" => "ListItem", "position" => i, "name" => name, "item" => base_url() <> path}
        end)
    }
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp base_url, do: RelayWeb.Endpoint.url()

  defp h(value), do: value |> to_string() |> Plug.HTML.html_escape()

  # Grafts a "what" phrase after "<Name> is …". Lowercases only a leading article
  # (A/An/The) so "The MySQL client" reads right mid-sentence, while proper nouns
  # ("Anthropic's …", "OpenAI's …") keep their capital.
  defp lead_phrase("A " <> _ = s), do: lower_first(s)
  defp lead_phrase("An " <> _ = s), do: lower_first(s)
  defp lead_phrase("The " <> _ = s), do: lower_first(s)
  defp lead_phrase(s), do: s

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(s), do: s

  defp slugify(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp strip_tags(s), do: String.replace(s, ~r/<[^>]*>/, "")
end
