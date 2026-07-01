defmodule OnlyTTYWeb.Site.Page do
  @moduledoc """
  Server-rendered marketing pages for OnlyTTY.

  Pages are plain HTML strings — no template engine, no `phoenix_html`/LiveView
  dependency — matching the dependency-light spirit of the rest of the project
  (the viewer is hand-written too). `layout/1` wraps every page in one head/nav/
  footer shell with the full SEO payload (canonical, Open Graph, Twitter, JSON-LD).

  All interpolated text flows through `h/1` (HTML-escaped). Tool slugs are looked
  up in `OnlyTTYWeb.Site.Tools` and never echoed from raw request input, so the only
  dynamic values that reach a page are from our own catalog.
  """

  alias OnlyTTYWeb.Site.Tools

  @github "https://github.com/AndrewDryga/onlytty"
  @og_image "/assets/og.png"

  # Cache-bust the served assets whenever their contents change, so returning
  # visitors never get a stale site.css/site.js. The version is a content hash of
  # both, computed at compile time; @external_resource makes an edit trigger a recompile.
  @css_path Path.join(__DIR__, "../../../priv/static/assets/site.css")
  @js_path Path.join(__DIR__, "../../../priv/static/assets/site.js")
  @mixpanel_path Path.join(__DIR__, "../../../priv/static/assets/mixpanel.js")
  @external_resource @css_path
  @external_resource @js_path
  @external_resource @mixpanel_path
  @assets_vsn [@css_path, @js_path, @mixpanel_path]
              |> Enum.map(fn p ->
                case File.read(p) do
                  {:ok, c} -> c
                  _ -> ""
                end
              end)
              |> then(&:crypto.hash(:sha, &1))
              |> Base.encode16(case: :lower)
              |> binary_part(0, 8)

  # ── Public page builders ──────────────────────────────────────────────────

  @doc "The home page."
  def home do
    layout(
      title: "OnlyTTY — your terminal, on your phone",
      description:
        "Run any command on your machine and drive it from your phone — Claude, Vim, k9s, psql, your whole shell. End-to-end encrypted, no inbound ports, nothing stored.",
      path: "/",
      json_ld: [website_ld(), software_ld(), faq_ld()],
      body:
        hero() <>
          trust_bar() <>
          tool_marquee() <>
          how_section() <>
          ciphertext_section() <>
          use_cases() <>
          features_section() <>
          home_tools() <> faq_section() <> start_section()
    )
  end

  @doc "A per-tool landing page. `tool` is a catalog map from `Tools`."
  def tool(tool) do
    layout(
      title: "Control #{tool.name} from your phone · OnlyTTY",
      description:
        "Run #{tool.name} on your machine and drive it from your phone with OnlyTTY. #{tool.why} End-to-end encrypted, opens view-only but anyone with the link can take control, nothing stored.",
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

  @doc "The self-hosting landing page — run your own relay."
  def self_hosting do
    layout(
      title: "Self-host OnlyTTY — run your own terminal-sharing relay",
      description:
        "Run your own OnlyTTY relay with one docker compose up: automatic HTTPS, no database, end-to-end encrypted. Self-host for your own domain, your own limits, or a network you control.",
      path: "/self-hosting",
      json_ld: [breadcrumb_simple_ld("Self-hosting", "/self-hosting"), selfhost_faq_ld()],
      body: selfhost_body()
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
    <p>Each session is reached by a link whose <code>#fragment</code> holds the secret. Anyone with the full link is a viewer, and — unless you started the session read-only — can take control and type into it. Treat the link like a password: share it deliberately, use <code>--control view-only</code> or <code>--passphrase</code> when you need to, and stop sharing by exiting the command.</p>
    <h2>No accounts, ephemeral sessions</h2>
    <p>There are no accounts. Sessions live in memory only; by default a session lasts as long as you keep it running and is gone the moment you stop it (set <code>--ttl</code> to expire it on a clock instead).</p>
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
    <h2>Analytics — on the marketing site only</h2>
    <p>These public marketing pages load <a href="https://mixpanel.com/legal/privacy-policy/" rel="noopener">Mixpanel</a> for product analytics: which pages are viewed, the referring link, and coarse device and usage data, kept in your browser’s local storage. Like any web request, Mixpanel receives your IP address (used for approximate location). There is no advertising and no ad-network tracking, and it honors your browser’s “Do Not Track” setting.</p>
    <h2>Never in the viewer</h2>
    <p>The terminal viewer (the <code>/s/…</code> pages) loads no analytics and no third-party scripts at all. A tracker there could leak the link’s <code>#fragment</code> secret, so the viewer’s Content-Security-Policy forbids any off-origin script or connection — by design.</p>
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
    <p>Email <a href="mailto:andrew@dryga.com">andrew@dryga.com</a> with details. For security vulnerabilities, see <a href="https://github.com/AndrewDryga/onlytty/blob/main/SECURITY.md">SECURITY.md</a>.</p>
    """)
  end

  @doc """
  The XML sitemap, built from the tool catalog so it can never drift from the
  pages that actually exist.
  """
  def sitemap do
    # No <priority>/<changefreq> — major engines ignore them — and no <lastmod>
    # since there's no real per-URL timestamp source to back it (faking it is worse).
    urls =
      ["/", "/tools", "/self-hosting", "/terms", "/privacy", "/acceptable-use"] ++
        Enum.map(Tools.all(), &"/control/#{&1.slug}")

    entries =
      Enum.map_join(urls, "\n", fn path ->
        "  <url><loc>#{base_url()}#{path}</loc></url>"
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
    <link rel="stylesheet" href="/assets/site.css?v=#{@assets_vsn}">
    #{ld_tags}
    </head>
    <body>
    #{nav()}
    <main>#{body}</main>
    #{footer()}
    #{script()}
    <script src="/assets/mixpanel.js?v=#{@assets_vsn}" defer></script>
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
          <a href="/self-hosting">Self-hosting</a>
          <a href="/#faq">FAQ</a>
        </nav>
        <div class="nav-cta">
          <a class="btn btn-ghost btn-sm nav-gh" href="#{@github}" rel="noopener" aria-label="GitHub">#{icon("github")}<span>GitHub</span></a>
          <a class="btn btn-primary btn-sm" href="/#start">Get started</a>
        </div>
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
          <p>Built by <a href="https://dryga.com" rel="noopener">Andrew Dryga</a> using <a href="https://coop.dryga.com" rel="noopener">co:op</a></p>
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
          <a href="/self-hosting">Self-hosting</a>
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
    </footer>
    """
  end

  # ── Home sections ─────────────────────────────────────────────────────────

  defp hero do
    # Hero rotation is deliberately agents/long-runners — tools you mostly watch
    # and steer with the odd interruption. Input-heavy tools (psql, editors,
    # shells) live on /tools and their own /control pages, not the hero.
    rotate = Jason.encode!(["claude", "codex", "aider", "gemini", "goose"])

    """
    <section class="hero">
      <div class="wrap hero-grid">
        <div class="hero-copy">
          <span class="badge"><span class="dot"></span>End-to-end encrypted</span>
          <h1>Want to control your <span class="hl" data-rotate='#{rotate}'>claude</span> while sitting on the toilet?</h1>
          <p class="lede">Run any command on your machine, scan the link it prints, and drive it from your phone. The relay in the middle only ever forwards ciphertext — your keystrokes stay yours.</p>
          <div class="cta-row">
            <a class="btn btn-primary" href="#start">Get started — it's free</a>
            <a class="btn btn-ghost" href="#how">See how it works</a>
          </div>
          <div class="hero-snippet">#{snippet("curl -fsSL https://onlytty.com/install.sh | sh")}</div>
        </div>
        <div class="hero-demo">#{term_demo("claude", "Claude Code", agent: true)}</div>
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
        <div class="section-head">
          <p class="eyebrow">how it works</p>
          <h2>Three steps. No port forwarding, no agents, no accounts.</h2>
        </div>
        <div class="steps">
          #{step("01", "Run it", "<code>onlytty -- claude</code> — or just <code>onlytty</code> to share your whole shell. It keeps running in your terminal and prints a link plus a QR code.")}
          #{step("02", "Scan it", "Open the link on your phone. The session secret rides in the URL <code>#fragment</code>, which never leaves the browser — so the relay can't read a thing.")}
          #{step("03", "Drive it", "Watch live, or tap <em>take control</em> to type — anyone with the link can, so share it like a key (or start <code>--control view-only</code>). Lose signal? It reconnects and picks up where you left off.")}
        </div>
      </div>
    </section>
    """
  end

  # The trust mechanism, shown not claimed: the same stream is readable on both ends
  # and opaque in the middle. The relay column is the real wire format (AEAD frames).
  defp ciphertext_section do
    plain =
      ~s(<span class="c-p">$</span> onlytty -- claude\n) <>
        ~s(<span class="c-dim">●</span> Read auth.ex\n) <>
        ~s(<span class="c-dim">●</span> Edited auth.ex <span class="c-ok">+18 −4</span>\n) <>
        ~s(<span class="c-dim">●</span> Ran mix test  <span class="c-ok">✓ 24 passed</span>)

    panel = fn label, dot, body, extra ->
      ~s(<figure class="cipher-panel"><figcaption><span class="cp-dot #{dot}"></span>#{label}</figcaption>) <>
        ~s(<pre class="cp-body">#{body}</pre>#{extra}</figure>)
    end

    arrow = ~s(<div class="cipher-arrow" aria-hidden="true">→</div>)

    """
    <section class="section cipher-sec">
      <div class="wrap">
        <div class="section-head">
          <p class="eyebrow">end-to-end encrypted</p>
          <h2>The relay forwards bytes it can't read.</h2>
          <p class="lede">Keys are derived from the secret in the link's <code>#fragment</code> — which the browser never sends to the server. Your machine and your phone hold the keys; the relay in the middle only ever sees ciphertext.</p>
        </div>
        <div class="cipher-flow" data-reveal>
          #{panel.("Your machine", "ok", plain, "")}
          #{arrow}
          #{panel.("What the relay sees", "warn", ~s(<span class="cipher" aria-hidden="true">#{cipher_lines()}</span>), ~s(<figcaption class="cp-note">opaque AEAD frames — no keys, ever</figcaption>))}
          #{arrow}
          #{panel.("Your phone", "ok", plain, "")}
        </div>
      </div>
    </section>
    """
  end

  defp features_section do
    """
    <section class="section alt">
      <div class="wrap">
        <div class="section-head">
          <p class="eyebrow">Security &amp; trust</p>
          <h2>A remote terminal you don't have to be nervous about.</h2>
        </div>
        <div class="bento" data-reveal>
          #{bento_tile("md", "shield", "No inbound ports", "The CLI dials out over TLS. Nothing listens on your machine, so your firewall stays exactly as shut as it is now.")}
          #{bento_tile("md", "trash", "Nothing persisted", "Live sessions live in memory and vanish when you exit the command. No accounts, no history, nothing written to disk, no logs of your bytes.")}
          #{bento_tile("sm", "wifi", "Survives bad Wi-Fi", "Your phone rides out dropouts, sleep, and dead zones — lose signal on the subway, resurface, and the viewer reconnects right where you left off.")}
          #{bento_tile("sm", "key", "The link is the key", "Anyone with the full link can watch and take control. Start it read-only, or add a passphrase the link alone can't decrypt.")}
          #{bento_tile("sm", "terminal", "Works with any CLI", "If it runs in a terminal, OnlyTTY shares it — agents, editors, REPLs, TUIs, or your whole shell.")}
        </div>
      </div>
    </section>
    """
  end

  defp home_tools do
    chips = Enum.map_join(Tools.featured(), "", &chip/1)

    """
    <section class="section">
      <div class="wrap">
        <div class="section-head">
          <p class="eyebrow">Compatibility</p>
          <h2>Pick your poison. There's a guide for each.</h2>
        </div>
        <div class="chips">#{chips}</div>
        <p class="more"><a class="btn btn-ghost" href="/tools">Browse all #{length(Tools.all())} tools →</a></p>
      </div>
    </section>
    """
  end

  defp use_cases do
    """
    <section class="section alt">
      <div class="wrap">
        <div class="section-head">
          <p class="eyebrow">Use cases</p>
          <h2>What you'll actually use it for.</h2>
        </div>
        <div class="uses">
          #{feature("bot", "Drive your AI agent", "Kick off Claude, Codex, or aider at your desk, then approve its plans and answer its questions from your phone while it works.")}
          #{feature("bell", "On-call from anywhere", "Pager goes off at dinner? Tail the logs, bounce the service, kill the runaway process — no scramble for a laptop.")}
          #{feature("eye", "Pair or demo, read-only", "Send a watch-only link so a teammate can follow your terminal live — debugging, onboarding, a quick demo — with no screen-share app.")}
          #{feature("activity", "Keep long jobs on a leash", "Start a migration, build, or training run, then keep an eye on it — and Ctrl-C it — from the couch.")}
        </div>
      </div>
    </section>
    """
  end

  defp faq_section do
    items = Enum.map_join(faqs(), "", fn {q, a} -> faq_item(q, a) end)

    """
    <section id="faq" class="section">
      <div class="wrap narrow">
        <div class="section-head">
          <p class="eyebrow">FAQ</p>
          <h2>Questions you're right to ask</h2>
        </div>
        <div class="faq">#{items}</div>
      </div>
    </section>
    """
  end

  defp start_section do
    """
    <section id="start" class="section start">
      <div class="wrap narrow">
        <div class="section-head">
          <p class="eyebrow">Get started</p>
          <h2>Your terminal is about to go public. To exactly one fan: you.</h2>
          <p class="lede"><b>Try it, it takes less than a minute.</b> Install the open-source CLI, then share a command — or your whole shell. It prints a link and a QR; scan it and you're live.</p>
        </div>
        <div class="start-card">
          <div class="examples">
            #{example_row("Install", "curl -fsSL https://onlytty.com/install.sh | sh")}
            #{example_row("Your whole shell", "onlytty")}
            #{example_row("One command", "onlytty -- claude")}
            #{example_row("Watch-only", "onlytty --control view-only -- htop")}
          </div>
        </div>
        <div class="cta-row"><a class="btn btn-primary" href="#{@github}" rel="noopener">Get the CLI on GitHub</a><a class="btn btn-ghost" href="/tools">See what you can control</a></div>
      </div>
    </section>
    """
  end

  defp example_row(label, cmd) do
    ~s(<div class="example"><span class="example-label">#{h(label)}</span>#{snippet(cmd)}</div>)
  end

  # ── Self-hosting page ───────────────────────────────────────────────────────

  defp selfhost_body do
    """
    <section class="section">
      <div class="wrap narrow">
        <nav class="crumbs" aria-label="Breadcrumb"><a href="/">Home</a> <span aria-hidden="true">›</span> <span>Self-hosting</span></nav>
        <p class="eyebrow">Self-hosting</p>
        <h1>Run your own OnlyTTY relay</h1>
        <p class="lede">One <code>docker compose up</code> brings up a relay on your domain, with automatic HTTPS. The relay is already end-to-end encrypted — it only ever forwards ciphertext — so you self-host for your <strong>own domain, your own limits, or a network you control</strong>, not for more privacy than the encryption already gives you.</p>
        <div class="cta-row"><a class="btn btn-primary" href="#{@github}/blob/main/SELF_HOSTING.md" rel="noopener">Read the self-hosting guide</a><a class="btn btn-ghost" href="#{@github}" rel="noopener">View source</a></div>
      </div>
    </section>

    <section class="section alt">
      <div class="wrap narrow">
        <div class="section-head">
          <p class="eyebrow">Quick start</p>
          <h2>Clone the bundle, set two values, bring it up</h2>
          <p class="lede">The <a href="#{@github}/tree/main/selfhost" rel="noopener"><code>selfhost/</code></a> bundle is a Compose file and a Caddyfile. Caddy fetches and renews a Let's Encrypt certificate for your domain on its own — no certbot, no cron.</p>
        </div>
        <div class="start-card">
          <div class="examples">
            #{example_row("Get the bundle", "git clone #{@github} && cd onlytty/selfhost")}
            #{example_row("Configure your domain + a secret", "cp .env.example .env")}
            #{example_row("Start — automatic HTTPS", "docker compose up -d")}
            #{example_row("Point your runner at it", "onlytty --server https://relay.example.com")}
          </div>
        </div>
      </div>
    </section>

    <section class="section">
      <div class="wrap">
        <div class="section-head">
          <p class="eyebrow">Why self-host</p>
          <h2>Reasons that hold up</h2>
        </div>
        <div class="bento" data-reveal>
          #{bento_tile("md", "key", "Your own domain", "Links read https://relay.example.com/s/… instead of onlytty.com — your brand, your URL, in every link and QR the runner prints.")}
          #{bento_tile("md", "shield", "Your own limits", "Cap session lifetime, concurrency, frame size, and create-rate to your policy with a handful of environment variables.")}
          #{bento_tile("md", "wifi", "A network you control", "Keep the relay inside a VPC, behind a VPN, or air-gapped, so links only ever resolve where you want them to.")}
          #{bento_tile("md", "lock", "You serve the viewer", "The browser viewer is code the relay host serves. Self-host and that code-delivery trust is yours, not a third party's.")}
        </div>
      </div>
    </section>

    <section class="section alt">
      <div class="wrap narrow">
        <div class="section-head">
          <p class="eyebrow">What you run</p>
          <h2>One stateless container, behind TLS</h2>
        </div>
        <p>The relay is a single Elixir container with <strong>no database</strong> — every session lives in memory, and nothing terminal-related is ever persisted, so there is nothing to back up. It needs exactly one thing in front of it: a TLS-terminating proxy. The bundle ships Caddy; bring your own nginx, Cloudflare, or Fly if you'd rather. The browser viewer uses the Web Crypto API, which only runs over HTTPS — so TLS isn't optional.</p>
        <p>Outgrow one node and it clusters: every session is registered cluster-wide, so a runner and a viewer that land on different instances still pair. Keep your <code>SECRET_KEY_BASE</code> safe; everything else is reproducible from the image.</p>
      </div>
    </section>

    <section id="faq" class="section">
      <div class="wrap narrow">
        <div class="section-head">
          <p class="eyebrow">FAQ</p>
          <h2>Before you run it</h2>
        </div>
        <div class="faq">#{Enum.map_join(selfhost_faqs(), "", fn {q, a} -> faq_item(q, a) end)}</div>
      </div>
    </section>

    <section class="section start">
      <div class="wrap narrow">
        <div class="section-head">
          <h2>From a fresh host to a working relay</h2>
          <p class="lede">The guide walks the whole path — the breeze setup, a bring-your-own-proxy config, the full configuration reference, and the security posture when you serve the viewer yourself.</p>
        </div>
        <div class="cta-row"><a class="btn btn-primary" href="#{@github}/blob/main/SELF_HOSTING.md" rel="noopener">Read the self-hosting guide</a><a class="btn btn-ghost" href="/">Back to OnlyTTY</a></div>
      </div>
    </section>
    """
  end

  defp selfhost_faqs do
    [
      {"Is it hard to run?",
       ~s(No. It's one container behind Caddy — <code>docker compose up -d</code> and Caddy fetches a TLS certificate for your domain on its own. There's no database to manage and nothing to back up.)},
      {"Does self-hosting change the security model?",
       ~s(End-to-end encryption is identical — the relay only ever forwards ciphertext. What changes is <em>code-delivery trust</em>: the browser viewer is JavaScript your relay serves, so your browser trusts your relay at load time. Pin a release tag and check the published viewer hashes against it. The full model is in the <a href="#{@github}/blob/main/SECURITY.md" rel="noopener">security model</a>.)},
      {"Do I need a database or backups?",
       ~s(No. Sessions live in memory only; nothing terminal-related is persisted. Keep your <code>SECRET_KEY_BASE</code> and the deployment is fully reproducible from the image.)},
      {"Can I run more than one node?",
       ~s(Yes. Every session is registered cluster-wide, so a runner and a viewer on different instances still pair. The production multi-node setup on GCP is in <a href="#{@github}/tree/main/infra" rel="noopener"><code>infra/</code></a>.)}
    ]
  end

  defp selfhost_faq_ld do
    %{
      "@context" => "https://schema.org",
      "@type" => "FAQPage",
      "mainEntity" =>
        Enum.map(selfhost_faqs(), fn {q, a} ->
          %{
            "@type" => "Question",
            "name" => q,
            "acceptedAnswer" => %{"@type" => "Answer", "text" => strip_tags(a)}
          }
        end)
    }
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
              <h2>More #{h(String.downcase(t.category))} to run from your phone</h2>
              <div class="chips">#{Enum.map_join(rs, "", &chip/1)}</div>
              <p class="more"><a class="btn btn-ghost" href="/tools">Browse all tools →</a></p>
            </div>
          </section>
          """
      end

    point = fn text -> ~s(<li>#{icon("check")}<span>#{text}</span></li>) end

    """
    <section class="hero tool-hero">
      <div class="wrap hero-grid">
        <div class="hero-copy">
          <nav class="crumbs" aria-label="Breadcrumb"><a href="/">Home</a> <span aria-hidden="true">›</span> <a href="/tools">Tools</a> <span aria-hidden="true">›</span> <span>#{h(t.name)}</span></nav>
          <p class="eyebrow">#{h(t.category)}</p>
          <h1>Control <span class="hl">#{h(t.name)}</span> from your phone</h1>
          <p class="lede">#{h(t.why)}</p>
          #{snippet("onlytty -- #{t.cmd}")}
          <div class="cta-row"><a class="btn btn-primary" href="#start">Get started</a><a class="btn btn-ghost" href="/tools">All tools</a></div>
        </div>
        <div class="hero-demo">#{term_demo(t.cmd, t.name)}</div>
      </div>
    </section>

    <section class="section alt">
      <div class="wrap narrow">
        <h2>#{h(t.name)} on your phone</h2>
        <p class="lede">#{h(t.name)} is #{h(lead_phrase(t.what))} OnlyTTY runs it on your own machine and hands you a private link to drive it from your phone — the terminal stays live where you launched it; your phone is just a second screen and keyboard.</p>
        <ul class="tool-points">
          #{point.("End-to-end encrypted — the relay only ever forwards ciphertext, never your keystrokes.")}
          #{point.(~s(View-only by default — but the link is the key: anyone with it can take control with a tap. Lock it to watching with <code>--control view-only</code>.))}
          #{point.("Nothing stored — sessions are in-memory and vanish when you exit; no account, no inbound ports.")}
        </ul>
        <p class="muted">New to OnlyTTY? <a href="/#how">See how it works</a> · <a href="/#faq">read the FAQ</a>.</p>
      </div>
    </section>

    #{related_html}

    <section id="start" class="section">
      <div class="wrap narrow">
        <div class="section-head">
          <p class="eyebrow">Get started</p>
          <h2>Run #{h(t.name)} from your phone in about 30 seconds</h2>
        </div>
        <div class="start-card">
          <div class="examples">
            #{example_row("Install the CLI", "curl -fsSL https://onlytty.com/install.sh | sh")}
            #{example_row("Share #{t.name}", "onlytty -- #{t.cmd}")}
          </div>
        </div>
        <p class="muted">It prints a link and a QR — scan it and you're live. <a href="/#start">More ways to run it →</a></p>
        <div class="cta-row"><a class="btn btn-primary" href="#{@github}" rel="noopener">Get the CLI on GitHub</a></div>
      </div>
    </section>
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
        <h1>If it runs in a terminal, you can run it from your phone.</h1>
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
        </div>
      </article>
      """
    )
  end

  # ── Small components ──────────────────────────────────────────────────────

  defp chip(t) do
    ~s(<a class="chip" href="/control/#{h(t.slug)}"><b>#{h(t.name)}</b><code>onlytty -- #{h(t.cmd)}</code></a>)
  end

  defp tool_card(t) do
    """
    <a class="card" href="/control/#{h(t.slug)}">
      <span class="card-name">#{h(t.name)}</span>
      <span class="card-what">#{h(t.what)}</span>
      <code class="card-cmd">onlytty -- #{h(t.cmd)}</code>
    </a>
    """
  end

  defp feature(icon_name, title, body) do
    ~s(<div class="feature"><span class="feature-icon" aria-hidden="true">#{icon(icon_name)}</span><h3>#{h(title)}</h3><p>#{h(body)}</p></div>)
  end

  defp bento_tile(size, icon_name, title, body) do
    ~s(<div class="b b-#{size}"><span class="feature-icon" aria-hidden="true">#{icon(icon_name)}</span><h3>#{h(title)}</h3><p>#{h(body)}</p></div>)
  end

  # An infinite, hover-pausable marquee of supported tools — the "works with
  # anything" signal. Names are duplicated so the CSS translateX(-50%) loop is
  # seamless. Decorative (aria-hidden); the same tools are linked accessibly in
  # the tool grid below and on /tools.
  defp tool_marquee do
    half =
      ~s(<span class="marquee-lead">works with</span>) <>
        Enum.map_join(Tools.featured(), "", &~s(<span class="marquee-item">#{h(&1.name)}</span>))

    ~s(<section class="marquee" aria-hidden="true"><div class="marquee-track">#{half}#{half}</div></section>)
  end

  # Decorative "ciphertext" for the big encryption tile — fixed hex, purely visual
  # (aria-hidden), so it never resembles real key material.
  defp cipher_lines do
    "9f3a c1d7 04e8 a52b 6f10 d9c4 3e7a 88b2\n" <>
      "e10b 77fc 2a4d 90e3 5b6a cc81 1f2e 4d70\n" <>
      "a3d9 0c5f e244 7b18 96aa 3fd1 c0e7 5a93\n" <>
      "47e2 b8d0 6c19 f3a7 22be 5d84 e9f1 0a6c"
  end

  # Crisp inline icons (Lucide-style, 24px stroke, currentColor) — consistent and
  # platform-independent, unlike emoji.
  defp icon(name) do
    paths =
      case name do
        "check" ->
          ~s(<path d="M20 6 9 17l-5-5"/>)

        "bot" ->
          ~s(<path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2"/><path d="M20 14h2"/><path d="M15 13v2"/><path d="M9 13v2"/>)

        "bell" ->
          ~s(<path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/><path d="M3.26 15.5C2.7 16.6 3.5 18 4.7 18h14.6c1.2 0 2-1.4 1.44-2.5C20 14 19 12.5 19 9a7 7 0 1 0-14 0c0 3.5-1 5-1.74 6.5"/>)

        "eye" ->
          ~s(<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/>)

        "activity" ->
          ~s(<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>)

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

        "github" ->
          ~s(<path d="M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 2c-.3 1.15-.3 2.35 0 3.5A5.4 5.4 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.39.49-.68 1.05-.85 1.65-.17.6-.22 1.23-.15 1.85v4"/><path d="M9 18c-4.51 2-5-2-7-2"/>)
      end

    ~s(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{paths}</svg>)
  end

  defp step(n, title, body) do
    # `body` here is trusted literal markup (contains <code>/<em>), so it is not escaped.
    ~s(<div class="step"><span class="num">#{n}</span><h3>#{h(title)}</h3><p>#{body}</p></div>)
  end

  defp faq_item(q, a) do
    # `a` is trusted literal markup (may contain links/code), so it is not escaped.
    "<details class=\"faq-item\"><summary>#{h(q)}</summary><div class=\"faq-a\">#{a}</div></details>"
  end

  defp snippet(text) do
    ~s(<div class="snippet"><code><span class="prompt">$</span> #{h(text)}</code><button class="copy" type="button" data-copy="#{h(text)}" aria-label="Copy command">Copy</button></div>)
  end

  # The hero visual: a terminal sharing `onlytty -- cmd` + a phone showing the same
  # session live. Parameterized by the command/name so each tool page shows its own.
  # Built with explicit newlines because <pre> is whitespace-sensitive; the relay
  # banner is identical for every command (see printBanner in main.go) — only the
  # invocation differs, so nothing tool-specific is fabricated.
  defp term_demo(cmd, name, opts \\ []) do
    # Keep lines short: the phone overlaps the bottom-right, so long lines would run
    # under it. These are stylized, not real wrapping output.
    lines = [
      ~s(<span class="c-p">$</span> onlytty -- #{h(cmd)}),
      :gap,
      ~s(<span class="c-b">onlytty — shared, end-to-end encrypted</span>),
      :gap,
      qr(),
      ~s(Link  <span class="c-link">onlytty.com/s/7q2k</span><span class="c-frag">#…</span>),
      ~s(Expires  never),
      :gap,
      ~s(<span class="c-dim">Scan it on your phone →</span>),
      :gap,
      ~s(<span class="c-ok">✻</span> <span class="c-b">#{h(name)}</span> <span class="c-dim">live</span>),
      prompt_tail(opts)
    ]

    body =
      lines
      |> Enum.with_index()
      |> Enum.map_join("\n", fn
        {:gap, _} -> ""
        {content, i} -> ~s(<span class="ln" style="--d:#{i * 90}ms">#{content}</span>)
      end)

    term =
      ~s(<div class="term">) <>
        ~s(<div class="term-bar"><span class="tdot r"></span><span class="tdot y"></span><span class="tdot g"></span><span class="term-title">#{h(name)} — onlytty</span><span class="term-live"><i></i>shared</span></div>) <>
        ~s(<pre class="term-body">) <> body <> ~s(</pre></div>)

    ~s(<div class="stage" role="img" aria-label="A terminal running 'onlytty -- #{h(cmd)}' shares an end-to-end-encrypted link; a phone shows the same #{h(name)} session live, ready to take control.">) <>
      term <> phone(name, opts) <> ~s(</div>)
  end

  # The last terminal/phone line. For an agent demo it's a synchronized "thinking"
  # animation (see thinking/0); otherwise a plain blinking cursor.
  defp prompt_tail(opts) do
    if opts[:agent],
      do: thinking(),
      else: ~s(<span class="c-p">›</span> <span class="cursor">█</span>)
  end

  # A Claude-style "thinking" line: a spinner + a cycling verb. The same data-think-*
  # nodes appear in the terminal and the phone, and one JS loop (script/0) advances
  # both in lockstep, so they animate identically at the same instant. With no JS or
  # reduced motion, the static "⠋ Thinking…" stands in.
  defp thinking do
    ~s(<span class="c-p" data-think-spin>⠋</span> <span class="c-dim" data-think-word>Thinking</span><span class="c-dim">…</span>)
  end

  # The phone overlay, modelled on the real mobile viewer (priv/static/viewer.html):
  # a status bar (connected + a control button), the terminal, and a key toolbar.
  defp phone(name, opts) do
    ~s(<div class="phone" aria-hidden="true"><div class="phone-scr">) <>
      ~s(<div class="phone-bar"><span class="phone-stat"><i></i>connected</span></div>) <>
      ~s(<div class="phone-term"><pre>) <>
      phone_body(name, opts) <>
      ~s(</pre></div>) <>
      ~s(<div class="phone-keys"><span>Esc</span><span>Tab</span><span>Ctrl</span><span>^C</span></div>) <>
      ~s(</div></div>)
  end

  # The phone's terminal — the same session as the desktop, mirrored on the phone.
  # For an agent it shows it working with the synced "thinking" line (thinking/0);
  # otherwise the tool running with a blinking prompt.
  defp phone_body(name, opts) do
    lines =
      if opts[:agent] do
        [
          ~s(<span class="c-dim">› refactor auth module</span>),
          ~s(<span class="c-ok">●</span> Read auth.ex),
          ~s(<span class="c-ok">●</span> Read auth_test.ex),
          ~s(<span class="c-ok">●</span> Edited auth.ex <span class="c-ok">+18</span> <span class="c-dim">−4</span>),
          ~s(<span class="c-ok">●</span> Edited auth_test.ex),
          ~s(<span class="c-ok">●</span> Ran mix test),
          ~s(<span class="c-dim">  ✓ 24 passed, 0 failed</span>),
          ~s(<span class="c-ok">●</span> Edited router.ex <span class="c-ok">+3</span>),
          ~s(<span class="c-ok">●</span> Ran mix format),
          ~s(<span class="c-ok">✻</span> <span class="c-dim">Done · 4 files</span>),
          ~s(<span class="c-dim">› now add rate limiting</span>),
          ~s(<span class="c-ok">✻</span> <span class="c-b">#{h(name)}</span>),
          thinking()
        ]
      else
        [
          ~s(<span class="c-ok">✻</span> <span class="c-b">#{h(name)}</span> <span class="c-dim">live</span>),
          ~s(<span class="c-ok">●</span> <span class="c-dim">view-only · tap to drive</span>),
          ~s(<span class="c-ok">●</span> <span class="c-dim">end-to-end encrypted</span>),
          ~s(<span class="c-ok">●</span> <span class="c-dim">single viewer</span>),
          ~s(<span class="c-ok">●</span> <span class="c-dim">no expiry</span>),
          prompt_tail(opts)
        ]
      end

    Enum.join(lines, "\n")
  end

  # A real, scannable QR drawn with terminal half-block characters — like the
  # real `onlytty` banner. Generated once with the same library and level the CLI
  # uses (qrterminal.GenerateHalfBlock at level M); shrunk to size via .qr-art.
  # (Go on, scan it.)
  defp qr do
    art =
      [
        "█████████████████████████████████████████",
        "█████████████████████████████████████████",
        "████ ▄▄▄▄▄ █▀█ ▄▄▀█ ▄▀▄ ▀▀▄ ▀█ ▄▄▄▄▄ ████",
        "████ █   █ ██   ▀▀██▄▀█ ▄▀██▄█ █   █ ████",
        "████ █▄▄▄█ █▄▄ ▀█▄▀██▄▀██▄▀███ █▄▄▄█ ████",
        "████▄▄▄▄▄▄▄█▄█ ▀▄▀ █ ▀ █ ▀ █ █▄▄▄▄▄▄▄████",
        "████ ▀ ▀▄█▄▀▀▀▀█ ▄▀▄ ▄█▄ ▄▀▄▀▀▀▀▄██▄█████",
        "█████▀▀▄▄█▄▄█▄█▄ ▄███▄██ ▄██ ▄ ▄▀█▄ ▄████",
        "████▄▄▄▄ █▄  ▀▀█ ██▀███ █▀█ ▄  ▄▄ █▄ ████",
        "████ █▀ ▄█▄█▄▄▄▀██▀▀█▀▀▀█▀▀▀█▄▀  ▄▄ ▄████",
        "████▄▀▀ ▀▄▄ ▄▄ ▀ ▄▀█  ▄█▄ ▀█▄▄ ▀█▄█▀▀████",
        "██████▀█▄▄▄▄▄▄▄▄▀▄▄▀ ▀ ▀▀▀ █▀▄ ▀▀█▄▄▄████",
        "████▄▄ █▄▄▄█▀ ▄ ██ ▀ █ ▀ ▀ ▀▀▄▄ █▄█ ▀████",
        "████▄▀▄ ▄▀▄▄ ▄█████▄  ▀▄ ▀███▄ ▄█ █▄ ████",
        "████▄█▄███▄█▀▀▀▄▀▀▄▄▀▄▀▄ ▄▀█ ▄▄▄  ██▀████",
        "████ ▄▄▄▄▄ ███  ▄▀▀▀█▄██▄▄█▄ █▄█ █▄▀ ████",
        "████ █   █ █▄█  ▄▀ ▀█▀█▀█▀██ ▄▄▄ ▄█  ████",
        "████ █▄▄▄█ █▄█▀ ▀██▀█ ▀▀█▀▀   ▀█ █▄▀▄████",
        "████▄▄▄▄▄▄▄█▄████▄██▄▄██▄▄█▄▄█▄█▄▄█▄▄████",
        "█████████████████████████████████████████",
        "▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"
      ]
      |> Enum.join("\n")

    ~s(<span class="qr-art" aria-hidden="true">) <> art <> ~s(</span>)
  end

  defp logo do
    ~s(<img class="logo" src="/assets/brand/mascot.png" width="24" height="30" alt="" aria-hidden="true">)
  end

  defp script do
    ~s(<script src="/assets/site.js?v=#{@assets_vsn}" defer></script>)
  end

  # ── Content data ──────────────────────────────────────────────────────────

  defp faqs do
    [
      {"Is this an OnlyFans thing?",
       "No. OnlyTTY is a developer tool with a cheeky name. The only content here is your own terminal, and the only subscriber is you. The joke is the branding; the end-to-end encryption is completely real."},
      {"Can the server see my terminal?",
       ~s(No. The session secret lives in the link's <code>#fragment</code>, which browsers never send to the server. Keys are derived from it, so the relay only ever forwards ciphertext. Read the <a href="#{@github}/blob/main/PROTOCOL.md" rel="noopener">protocol</a> and <a href="#{@github}/blob/main/SECURITY.md" rel="noopener">security model</a> yourself.)},
      {"Do I have to open a port or install an agent?",
       "No inbound ports and no daemon. The <code>onlytty</code> CLI dials out over WebSocket/TLS, so nothing listens on your machine. It's a single Go binary."},
      {"Who can take control of my session?",
       ~s(Anyone with the full link. The link is the key: whoever opens it can watch — and can tap <em>take control</em> to type. Read-only is just the default view, not a per-person gate, so share the link like a password. Want watch-only? Start with <code>--control view-only</code>. Want a second factor? Add <code>--passphrase</code>, and the link alone won't decrypt. Either way, exit the command to stop sharing instantly.)},
      {"What can I actually control?",
       ~s(Anything that runs in a terminal: AI coding agents, editors, REPLs, database shells, ops TUIs, or your whole <code>\$SHELL</code>. Browse the <a href="/tools">full list</a> for ready-made guides.)},
      {"Is it really free and open source?",
       ~s(Yes. The relay and the CLI are open source — <a href="#{@github}" rel="noopener">audit the code</a> or <a href="/self-hosting">run your own relay</a> with one <code>docker compose up</code> and automatic HTTPS. No accounts, no tracking.)},
      {"How long does a session last, and what if my connection drops?",
       ~s(As long as you keep it running — there's no expiry by default. Your phone or laptop rides out flaky networks, sleep, and dead zones, reconnecting on its own, so you can drop off Wi-Fi and pick right back up. Want it to self-destruct on a clock? Set <code>--ttl</code>. When you exit the command, it's gone — the relay stores nothing.)}
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
      "operatingSystem" => "macOS, Linux",
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
      "operatingSystem" => "macOS, Linux",
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

  defp base_url, do: OnlyTTYWeb.Endpoint.url()

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
