defmodule OnlyttyWeb.PageController do
  @moduledoc """
  The OnlyTTY marketing site: the home page, the per-tool landing pages, the tool
  index, and the XML sitemap. Pages are rendered as plain HTML strings by
  `OnlyttyWeb.Site.Page`; this controller just maps routes to them.
  """

  use OnlyttyWeb, :controller

  alias OnlyttyWeb.Site.{Page, Tools}

  @doc "`GET /` — the home page."
  def home(conn, _params), do: html(conn, Page.home())

  @doc "`GET /tools` — the full, browse-by-category tool index."
  def tools(conn, _params), do: html(conn, Page.tools_index())

  @doc "`GET /terms` — Terms of Service."
  def terms(conn, _params), do: html(conn, Page.terms())

  @doc "`GET /privacy` — Privacy Policy."
  def privacy(conn, _params), do: html(conn, Page.privacy())

  @doc "`GET /acceptable-use` — Acceptable Use Policy."
  def acceptable_use(conn, _params), do: html(conn, Page.acceptable_use())

  @doc """
  `GET /control/:slug` — a per-tool landing page. Unknown slugs render a branded
  404; the slug is only ever looked up in the catalog, never echoed back.
  """
  def tool(conn, %{"slug" => slug}) do
    case Tools.get(slug) do
      nil -> conn |> put_status(:not_found) |> html(Page.not_found())
      tool -> html(conn, Page.tool(tool))
    end
  end

  @doc "`GET /sitemap.xml` — sitemap built from the tool catalog."
  def sitemap(conn, _params) do
    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, Page.sitemap())
  end
end
