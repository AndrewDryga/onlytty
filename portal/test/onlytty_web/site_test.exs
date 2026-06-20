defmodule OnlyttyWeb.SiteTest do
  @moduledoc "The OnlyTTY marketing site: home, tool pages, tools index, sitemap, SEO."
  use OnlyttyWeb.ConnCase, async: true

  alias OnlyttyWeb.Site.Tools

  describe "GET /" do
    test "renders the home page with the brand and the hook", %{conn: conn} do
      conn = get(conn, ~p"/")
      body = html_response(conn, 200)
      assert body =~ "OnlyTTY"
      assert body =~ "while sitting on the toilet?"
      assert body =~ "relay -- claude"
    end

    test "includes the core SEO tags", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~s(rel="canonical")
      assert body =~ ~s(name="description")
      assert body =~ ~s(property="og:title")
      assert body =~ ~s(name="twitter:card")
      assert body =~ "/assets/og.png"
      assert body =~ ~s(name="robots" content="index,follow")
      assert body =~ "/assets/site.css"
    end

    test "embeds WebSite, SoftwareApplication and FAQ structured data", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~s("@type":"WebSite")
      assert body =~ ~s("@type":"SoftwareApplication")
      assert body =~ ~s("@type":"FAQPage")
    end

    test "links into the tool catalog", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~s(href="/tools")
      assert body =~ ~s(href="/control/claude")
    end

    test "shows the brand mascot logo and the use-cases section", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "/assets/brand/mascot.png"
      assert body =~ "Use cases"
      assert body =~ "Drive your AI agent"
    end
  end

  describe "GET /control/:slug" do
    test "renders a known tool page with a tailored, indexable heading", %{conn: conn} do
      conn = get(conn, ~p"/control/claude")
      body = html_response(conn, 200)
      assert body =~ "Want to control"
      assert body =~ "Claude Code"
      assert body =~ "relay -- claude"
      assert body =~ ~s(rel="canonical")
      assert body =~ "/control/claude"
      assert body =~ ~s("@type":"BreadcrumbList")
      assert body =~ ~s(name="robots" content="index,follow")
    end

    test "every catalog tool renders a 200 page", %{conn: conn} do
      for tool <- Tools.all() do
        conn = get(conn, "/control/#{tool.slug}")
        body = html_response(conn, 200)
        assert body =~ tool.name, "expected #{tool.slug} page to mention #{tool.name}"
        # The command is HTML-escaped on the page (e.g. quotes in `watch`'s cmd).
        assert body =~ Plug.HTML.html_escape("relay -- #{tool.cmd}")
      end
    end

    test "an unknown slug returns a branded, noindex 404 and does not echo the slug", %{
      conn: conn
    } do
      conn = get(conn, "/control/totally-not-a-real-tool-xyz")
      body = html_response(conn, 404)
      assert body =~ "OnlyTTY"
      assert body =~ "/assets/brand/mascot.png"
      assert body =~ ~s(content="noindex,follow")
      # The slug must never be reflected into the page (no injection surface).
      refute body =~ "totally-not-a-real-tool-xyz"
    end
  end

  describe "GET /tools" do
    test "lists every category and links to tools", %{conn: conn} do
      body = conn |> get(~p"/tools") |> html_response(200)

      for category <- Tools.categories() do
        # Category names containing "&" are HTML-escaped in the page.
        assert body =~ Plug.HTML.html_escape(category),
               "expected /tools to list category #{category}"
      end

      assert body =~ ~s(href="/control/htop")
      assert body =~ ~s(rel="canonical")
    end
  end

  describe "GET /sitemap.xml" do
    test "lists the home page, the index and every tool", %{conn: conn} do
      conn = get(conn, ~p"/sitemap.xml")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/xml"

      body = conn.resp_body
      assert body =~ "<urlset"
      assert body =~ "/control/claude</loc>"
      assert body =~ "/tools</loc>"
      assert body =~ "/privacy</loc>"

      # one <loc> per tool, plus home, the index, and the 3 legal pages.
      loc_count = body |> String.split("<loc>") |> length() |> Kernel.-(1)
      assert loc_count == length(Tools.all()) + 5
    end
  end

  describe "legal pages" do
    test "terms, privacy and acceptable-use render with honest, accurate content", %{conn: conn} do
      terms = conn |> get(~p"/terms") |> html_response(200)
      assert terms =~ "Terms of Service"
      assert terms =~ "end-to-end"

      privacy = conn |> get(~p"/privacy") |> html_response(200)
      assert privacy =~ "Privacy Policy"
      assert privacy =~ "in memory"
      assert privacy =~ "8-character session-id"
      # states it does not log IPs or terminal content
      assert privacy =~ "IP addresses" and privacy =~ "terminal content"

      aup = conn |> get(~p"/acceptable-use") |> html_response(200)
      assert aup =~ "Acceptable Use"
      assert aup =~ "covert tunnel"
      assert aup =~ "andrew@dryga.com"
    end

    test "every page footer links the legal pages", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~s(href="/terms")
      assert body =~ ~s(href="/privacy")
      assert body =~ ~s(href="/acceptable-use")
    end
  end

  describe "static SEO files" do
    test "robots.txt allows crawling, blocks sessions, and points to the sitemap", %{conn: conn} do
      body = conn |> get("/robots.txt") |> response(200)
      assert body =~ "Sitemap: https://onlytty.com/sitemap.xml"
      assert body =~ "Disallow: /s/"
      assert body =~ "Allow: /"
    end
  end
end
