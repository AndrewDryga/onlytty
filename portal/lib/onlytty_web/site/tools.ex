defmodule OnlyTTYWeb.Site.Tools do
  @moduledoc """
  The catalog of CLI tools featured on the marketing site.

  This is the single source of truth: the home-page tool grid, the per-tool
  landing pages at `/control/:slug`, the `/tools` index, and the sitemap all read
  from `all/0`. Adding a tool here adds a fully-formed, indexable landing page —
  no template or route changes required.

  Each entry is a plain map:

    * `:slug`     — URL segment (lowercase, URL-safe). Whitelisted; the controller
                    only renders slugs that exist here, so the slug never reaches
                    the page from untrusted input.
    * `:name`     — display name used in headings and copy.
    * `:cmd`      — the command shown after `onlytty --` in the run snippet.
    * `:category` — one of `categories/0`, used to group the grid and index.
    * `:what`     — one sentence: what the tool is.
    * `:why`      — one sentence: why driving it from your phone is worth it.

  Every tool renders a `/control/:slug` page, but only the higher-intent ones are
  search-indexable — the long-tail slugs in `@noindex_slugs` render `noindex` and
  are left out of the sitemap (see `indexable?/1`) to keep a large set of
  near-duplicate pages from dragging on site-wide quality signals.
  """

  @categories [
    "AI coding agents",
    "AI on the command line",
    "Editors",
    "Shells & multiplexers",
    "Git & ops TUIs",
    "REPLs & databases",
    "Infra & remote",
    "File managers & fun"
  ]

  @tools [
    # ── AI coding agents ────────────────────────────────────────────────────
    %{
      slug: "claude",
      name: "Claude Code",
      cmd: "claude",
      category: "AI coding agents",
      what:
        "Anthropic's agentic coding assistant that edits files, runs commands, and ships whole features from your terminal.",
      why:
        "Start a refactor at your desk, then approve its plan and answer its questions from your phone while it keeps working."
    },
    %{
      slug: "codex",
      name: "Codex",
      cmd: "codex",
      category: "AI coding agents",
      what: "OpenAI's command-line coding agent that reads your repo and writes code on request.",
      why:
        "Queue a task, then reply to its prompts the moment they appear instead of waiting at the keyboard."
    },
    %{
      slug: "gemini",
      name: "Gemini CLI",
      cmd: "gemini",
      category: "AI coding agents",
      what: "Google's open-source AI agent that brings Gemini models into your terminal.",
      why:
        "Approve each tool call and redirect its reasoning on the spot, so a long run never stalls waiting on you."
    },
    %{
      slug: "aider",
      name: "Aider",
      cmd: "aider",
      category: "AI coding agents",
      what:
        "An AI pair programmer that edits code in your local git repo and commits as it goes.",
      why:
        "Read every diff before it lands — aider waits for your tap to commit, so you stay the reviewer from anywhere."
    },
    %{
      slug: "opencode",
      name: "OpenCode",
      cmd: "opencode",
      category: "AI coding agents",
      what: "An open-source terminal coding agent you can point at any model.",
      why: "Point it at any model and let it work a backlog while you supervise from your pocket."
    },
    %{
      slug: "crush",
      name: "Crush",
      cmd: "crush",
      category: "AI coding agents",
      what: "Charm's glamorous AI coding agent for the terminal.",
      why:
        "Its polished TUI stays legible on a small screen, so one-tap approvals are quick on a phone."
    },
    %{
      slug: "goose",
      name: "Goose",
      cmd: "goose",
      category: "AI coding agents",
      what: "An on-machine AI agent that automates engineering tasks end to end.",
      why:
        "Authorize the risky step the instant it asks, instead of walking back to your laptop to unblock it."
    },
    %{
      slug: "cursor-agent",
      name: "Cursor CLI",
      cmd: "cursor-agent",
      category: "AI coding agents",
      what: "Cursor's headless agent that runs your coding tasks from the command line.",
      why: "Keep the agent moving between meetings — answer its prompts the second they surface."
    },
    %{
      slug: "amp",
      name: "Amp",
      cmd: "amp",
      category: "AI coding agents",
      what: "An agentic coding tool that works across your whole codebase.",
      why: "Review its cross-repo plan and unblock it away from your desk, no laptop required."
    },

    # ── AI on the command line ──────────────────────────────────────────────
    %{
      slug: "llm",
      name: "llm",
      cmd: "llm chat",
      category: "AI on the command line",
      what: "A CLI for prompting models and piping the results anywhere.",
      why:
        "Kick off a long generation and read the result the moment it lands, without staying at the keyboard."
    },
    %{
      slug: "ollama",
      name: "Ollama",
      cmd: "ollama run llama3",
      category: "AI on the command line",
      what: "Run open large language models locally with a single command.",
      why:
        "Chat with a model your own GPU is running, from anywhere on your network — the weights never leave your box."
    },
    %{
      slug: "sgpt",
      name: "Shell GPT",
      cmd: "sgpt --repl temp",
      category: "AI on the command line",
      what: "A command-line tool that turns prompts into shell commands and answers.",
      why: "Ask for the exact command you forgot and drop it straight back into your shell."
    },
    %{
      slug: "mods",
      name: "Mods",
      cmd: "mods",
      category: "AI on the command line",
      what: "AI for the command line that pipes model output straight into your workflow.",
      why: "Watch the model's answer stream into your pipeline while you're away from the desk."
    },
    %{
      slug: "copilot",
      name: "GitHub Copilot CLI",
      cmd: "copilot",
      category: "AI on the command line",
      what:
        "GitHub's agentic AI assistant for the terminal that fixes bugs, builds features, and runs tasks on your code.",
      why:
        "Start a task at your desk and approve each step it takes against your repo from your phone."
    },

    # ── Editors ─────────────────────────────────────────────────────────────
    %{
      slug: "vim",
      name: "Vim",
      cmd: "vim",
      category: "Editors",
      what: "The ubiquitous modal text editor that lives in every terminal.",
      why:
        "Fix a one-line config or a commit message on a remote box — assuming you still remember how to quit."
    },
    %{
      slug: "nvim",
      name: "Neovim",
      cmd: "nvim",
      category: "Editors",
      what: "A hyperextensible, Lua-powered fork of Vim.",
      why:
        "Drive your fully-configured IDE-in-a-terminal, plugins and LSP and all, from the smallest screen you own."
    },
    %{
      slug: "emacs",
      name: "Emacs",
      cmd: "emacs -nw",
      category: "Editors",
      what: "The extensible, self-documenting editor that's basically an operating system.",
      why:
        "Check your org-agenda or run an M-x command against your live session while you're out."
    },
    %{
      slug: "nano",
      name: "Nano",
      cmd: "nano",
      category: "Editors",
      what: "The friendly, no-modes terminal editor for quick edits.",
      why: "Make a quick edit to a remote file without memorizing a single keybinding."
    },
    %{
      slug: "helix",
      name: "Helix",
      cmd: "hx",
      category: "Editors",
      what: "A post-modern modal editor with multiple selections and tree-sitter built in.",
      why:
        "Open a file and edit it with multiple selections — nothing to install or configure on a fresh box."
    },
    %{
      slug: "micro",
      name: "Micro",
      cmd: "micro",
      category: "Editors",
      what: "A modern terminal editor with mouse support and sane keybindings.",
      why: "Edit a remote file with the plain Ctrl-key shortcuts your thumbs already know."
    },

    # ── Shells & multiplexers ───────────────────────────────────────────────
    %{
      slug: "tmux",
      name: "tmux",
      cmd: "tmux attach",
      category: "Shells & multiplexers",
      what: "A terminal multiplexer that keeps your sessions alive across disconnects.",
      why: "Reattach to every session you left running and check on all of it from your phone."
    },
    %{
      slug: "screen",
      name: "GNU Screen",
      cmd: "screen -r",
      category: "Shells & multiplexers",
      what: "The original terminal multiplexer for persistent sessions.",
      why: "Peek at a long-running job in a detached session without opening a fresh SSH login."
    },
    %{
      slug: "zellij",
      name: "Zellij",
      cmd: "zellij",
      category: "Shells & multiplexers",
      what: "A modern terminal workspace with panes, tabs, and layouts.",
      why: "Carry your whole paned workspace in your pocket and jump between panes with a tap."
    },
    %{
      slug: "bash",
      name: "Bash",
      cmd: "bash",
      category: "Shells & multiplexers",
      what: "The shell that runs the world.",
      why: "Run a quick one-off command on your box without booting up a laptop."
    },
    %{
      slug: "zsh",
      name: "Zsh",
      cmd: "zsh",
      category: "Shells & multiplexers",
      what: "A powerful shell with great completion and a thriving plugin scene.",
      why: "Reach your fully-themed shell, completions and history and all, from your phone."
    },
    %{
      slug: "fish",
      name: "fish",
      cmd: "fish",
      category: "Shells & multiplexers",
      what: "The friendly interactive shell with autosuggestions out of the box.",
      why: "Let autosuggestions finish each command as you tap it out on a small keyboard."
    },
    %{
      slug: "nushell",
      name: "Nushell",
      cmd: "nu",
      category: "Shells & multiplexers",
      what: "A shell that treats your data as structured tables.",
      why: "Query a log as a structured table and scroll the rows on a phone screen."
    },

    # ── Git & ops TUIs ──────────────────────────────────────────────────────
    %{
      slug: "lazygit",
      name: "Lazygit",
      cmd: "lazygit",
      category: "Git & ops TUIs",
      what: "A blazing-fast terminal UI for git.",
      why: "Stage hunks, write a commit, and resolve a conflict with one thumb mid-review."
    },
    %{
      slug: "gitui",
      name: "GitUI",
      cmd: "gitui",
      category: "Git & ops TUIs",
      what: "A fast, keyboard-driven terminal UI for git, written in Rust.",
      why: "Work through your staging area with its keyboard-first flow, now on a touch screen."
    },
    %{
      slug: "tig",
      name: "tig",
      cmd: "tig",
      category: "Git & ops TUIs",
      what: "A text-mode interface for browsing git history.",
      why: "Scroll the commit history on your phone to pinpoint the change that broke the build."
    },
    %{
      slug: "lazydocker",
      name: "Lazydocker",
      cmd: "lazydocker",
      category: "Git & ops TUIs",
      what: "A terminal UI for managing Docker and docker-compose.",
      why: "Restart a flailing container the moment the alert fires, away from your desk."
    },
    %{
      slug: "k9s",
      name: "K9s",
      cmd: "k9s",
      category: "Git & ops TUIs",
      what: "A terminal UI to observe and manage your Kubernetes clusters.",
      why: "Watch pods and tail logs through an incident without scrambling for a laptop."
    },
    %{
      slug: "htop",
      name: "htop",
      cmd: "htop",
      category: "Git & ops TUIs",
      what: "An interactive process viewer for the terminal.",
      why: "Spot a runaway process and send it a signal before it eats the box."
    },
    %{
      slug: "btop",
      name: "btop",
      cmd: "btop",
      category: "Git & ops TUIs",
      what: "A gorgeous resource monitor for CPU, memory, disk, and network.",
      why: "Keep an eye on CPU, memory, and network while a heavy job runs on the server."
    },
    %{
      slug: "glances",
      name: "Glances",
      cmd: "glances",
      category: "Git & ops TUIs",
      what: "A cross-platform system monitor that shows everything at a glance.",
      why: "See a box's whole health at once on a screen that fits in your hand."
    },

    # ── REPLs & databases ───────────────────────────────────────────────────
    %{
      slug: "python",
      name: "Python REPL",
      cmd: "python",
      category: "REPLs & databases",
      what: "The interactive Python interpreter.",
      why: "Test a snippet or inspect a live object without getting back to your desk."
    },
    %{
      slug: "ipython",
      name: "IPython",
      cmd: "ipython",
      category: "REPLs & databases",
      what: "A rich interactive Python shell with magic commands.",
      why: "Re-run a cell and read its output remotely, magics and all."
    },
    %{
      slug: "node",
      name: "Node.js REPL",
      cmd: "node",
      category: "REPLs & databases",
      what: "The interactive JavaScript runtime.",
      why:
        "Try a JavaScript one-liner against the live runtime while you're away from the keyboard."
    },
    %{
      slug: "irb",
      name: "IRB",
      cmd: "irb",
      category: "REPLs & databases",
      what: "Ruby's interactive console.",
      why: "Poke at a Ruby object or run a quick experiment between other things."
    },
    %{
      slug: "iex",
      name: "IEx",
      cmd: "iex",
      category: "REPLs & databases",
      what: "Elixir's interactive shell, great for poking at a running system.",
      why: "Connect to your running app and run a diagnostic command from your phone."
    },
    %{
      slug: "psql",
      name: "psql",
      cmd: "psql",
      category: "REPLs & databases",
      what: "PostgreSQL's interactive terminal.",
      why: "Run that read-only query you forgot before the deploy, straight from your phone."
    },
    %{
      slug: "mysql",
      name: "mysql",
      cmd: "mysql",
      category: "REPLs & databases",
      what: "The MySQL command-line client.",
      why: "Check a row count or a slow query without booting up a database GUI."
    },
    %{
      slug: "redis-cli",
      name: "redis-cli",
      cmd: "redis-cli",
      category: "REPLs & databases",
      what: "The Redis command-line interface.",
      why: "Inspect a key or flush a cache the moment on-call needs it done."
    },
    %{
      slug: "mongosh",
      name: "mongosh",
      cmd: "mongosh",
      category: "REPLs & databases",
      what: "The modern MongoDB shell.",
      why: "Run a quick find() against a collection from the smallest device you own."
    },
    %{
      slug: "sqlite3",
      name: "SQLite",
      cmd: "sqlite3 app.db",
      category: "REPLs & databases",
      what: "The SQLite command-line shell.",
      why: "Query a database file in place on the box, without copying it anywhere first."
    },

    # ── Infra & remote ──────────────────────────────────────────────────────
    %{
      slug: "docker",
      name: "Docker",
      cmd: "docker stats",
      category: "Infra & remote",
      what: "Build, run, and manage containers from the command line.",
      why: "Bounce a service or read its live stats the moment the pager goes off."
    },
    %{
      slug: "kubectl",
      name: "kubectl",
      cmd: "kubectl get pods -w",
      category: "Infra & remote",
      what: "The Kubernetes command-line tool.",
      why: "Scale a deployment or read cluster events during an incident, away from your laptop."
    },
    %{
      slug: "terraform",
      name: "Terraform",
      cmd: "terraform plan",
      category: "Infra & remote",
      what: "Provision and change infrastructure as code.",
      why:
        "Read the plan carefully and type the apply with the diff in front of you, not from memory."
    },
    %{
      slug: "ansible",
      name: "Ansible",
      cmd: "ansible-playbook site.yml",
      category: "Infra & remote",
      what: "Automate configuration across your fleet with playbooks.",
      why: "Kick off a playbook and follow it rolling across your fleet, task by task."
    },
    %{
      slug: "mosh",
      name: "Mosh",
      cmd: "mosh user@host",
      category: "Infra & remote",
      what: "A resilient remote shell that survives flaky connections.",
      why: "Stay attached to your server through flaky mobile signal and network roaming."
    },
    %{
      slug: "watch",
      name: "watch",
      cmd: "watch -n1 'kubectl get pods'",
      category: "Infra & remote",
      what: "Run a command repeatedly and watch the output update.",
      why: "Keep an eye on a number that has to change before you can call the job done."
    },

    # ── File managers & fun ─────────────────────────────────────────────────
    %{
      slug: "ranger",
      name: "Ranger",
      cmd: "ranger",
      category: "File managers & fun",
      what: "A Vim-inspired terminal file manager with previews.",
      why: "Browse and preview files on the box like a pocket-sized file manager."
    },
    %{
      slug: "nnn",
      name: "nnn",
      cmd: "nnn",
      category: "File managers & fun",
      what: "A blazing-fast, lightweight terminal file manager.",
      why: "Find and move a file fast, no mouse and no lag."
    },
    %{
      slug: "mc",
      name: "Midnight Commander",
      cmd: "mc",
      category: "File managers & fun",
      what: "The classic two-pane terminal file manager.",
      why: "Copy files between its two panes on a remote box, one tap at a time."
    },
    %{
      slug: "weechat",
      name: "WeeChat",
      cmd: "weechat",
      category: "File managers & fun",
      what: "A fast, extensible terminal chat client for IRC and more.",
      why: "Stay in your IRC channels through your own client, no separate chat app to install."
    },
    %{
      slug: "irssi",
      name: "Irssi",
      cmd: "irssi",
      category: "File managers & fun",
      what: "The venerable terminal IRC client.",
      why: "Lurk in your favorite channels and fire off a reply between other things."
    },
    %{
      slug: "neomutt",
      name: "NeoMutt",
      cmd: "neomutt",
      category: "File managers & fun",
      what: "A powerful terminal email client.",
      why: "Triage your inbox with keyboard shortcuts — yes, on a phone."
    },
    %{
      slug: "newsboat",
      name: "Newsboat",
      cmd: "newsboat",
      category: "File managers & fun",
      what: "An RSS/Atom feed reader for the terminal.",
      why: "Catch up on your RSS feeds in a spare few minutes."
    },
    %{
      slug: "taskwarrior",
      name: "Taskwarrior",
      cmd: "task",
      category: "File managers & fun",
      what: "A command-line to-do manager that's surprisingly powerful.",
      why: "Capture the task you just thought of before it slips away."
    },
    %{
      slug: "cmus",
      name: "cmus",
      cmd: "cmus",
      category: "File managers & fun",
      what: "A small, fast terminal music player.",
      why: "Skip a track or requeue an album without leaving the terminal."
    },
    %{
      slug: "cmatrix",
      name: "cmatrix",
      cmd: "cmatrix",
      category: "File managers & fun",
      what: "Falling green code, just like the movie.",
      why: "Summon a wall of falling green code on your desktop from across the room."
    },
    %{
      slug: "cointop",
      name: "cointop",
      cmd: "cointop",
      category: "File managers & fun",
      what: "A fast terminal UI for tracking cryptocurrency prices.",
      why: "Watch crypto prices tick over in real time between other things."
    }
  ]

  # Slugs whose `/control/:slug` page is intentionally kept out of the search index
  # (noindex + dropped from the sitemap). These are near-duplicate long-tail pages
  # with low standalone search intent — generic shells (that's just `onlytty`
  # sharing your whole shell), plain REPLs, duplicative TUIs, and the whole
  # "File managers & fun" set. They STILL render and stay linked from `/tools`, so
  # nothing is orphaned; they just don't dilute the indexable set. The high-intent
  # pages (all AI agents, big editors/multiplexers/ops TUIs, DB + core infra) stay
  # indexable. See `sitemap/0` and the tool page's `robots` handling in `Page`.
  @noindex_slugs MapSet.new(~w(sgpt mods nano micro bash zsh fish nushell gitui tig glances
                      python ipython node irb iex mongosh sqlite3 ansible mosh watch
                      ranger nnn mc weechat irssi neomutt newsboat taskwarrior cmus
                      cmatrix cointop))

  @doc "All tools, in catalog order."
  def all, do: @tools

  @doc "The ordered list of category names."
  def categories, do: @categories

  @doc "Look up a tool by slug, or `nil` if there's no such tool."
  def get(slug), do: Enum.find(@tools, &(&1.slug == slug))

  @doc """
  Whether a tool's `/control/:slug` page should be search-indexable. Long-tail,
  near-duplicate pages (see `@noindex_slugs`) return `false` — they still render
  and stay linked from `/tools`, but carry `noindex` and are left out of the sitemap.
  Accepts a tool map or a slug string.
  """
  def indexable?(%{slug: slug}), do: indexable?(slug)
  def indexable?(slug) when is_binary(slug), do: not MapSet.member?(@noindex_slugs, slug)

  @doc "The tools whose pages are search-indexable, in catalog order."
  def indexable, do: Enum.filter(@tools, &indexable?/1)

  @doc "Tools grouped by category, returned in `categories/0` order."
  def by_category do
    Enum.map(@categories, fn cat ->
      {cat, Enum.filter(@tools, &(&1.category == cat))}
    end)
  end

  @doc """
  A curated set of slugs to feature on the home page, in display order. Keeps the
  home grid tight while `/tools` shows the full catalog.
  """
  def featured_slugs do
    ~w(claude codex gemini aider vim nvim tmux lazygit k9s htop psql docker
       kubectl iex python node redis-cli ollama crush ranger cmatrix cointop)
  end

  @doc "The featured tools, in `featured_slugs/0` order."
  def featured do
    # Tolerate slugs removed from the catalog, so editing @tools never breaks the page.
    featured_slugs() |> Enum.map(&get/1) |> Enum.reject(&is_nil/1)
  end
end
