defmodule RelayWeb.Site.Tools do
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
    * `:cmd`      — the command shown after `relay --` in the run snippet.
    * `:category` — one of `categories/0`, used to group the grid and index.
    * `:what`     — one sentence: what the tool is.
    * `:why`      — one sentence: why driving it from your phone is worth it.
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
        "Kick off a refactor at your desk, then approve its plan and steer it from your phone — even mid-flush."
    },
    %{
      slug: "codex",
      name: "Codex",
      cmd: "codex",
      category: "AI coding agents",
      what: "OpenAI's command-line coding agent that reads your repo and writes code on request.",
      why: "Queue a task before you get up and answer its questions the moment they pop up."
    },
    %{
      slug: "gemini",
      name: "Gemini CLI",
      cmd: "gemini",
      category: "AI coding agents",
      what: "Google's open-source AI agent that brings Gemini models into your terminal.",
      why: "Approve tool calls and nudge its reasoning without breaking your bathroom break."
    },
    %{
      slug: "aider",
      name: "Aider",
      cmd: "aider",
      category: "AI coding agents",
      what:
        "An AI pair programmer that edits code in your local git repo and commits as it goes.",
      why:
        "Confirm each diff from the couch — aider waits politely for your tap before it commits."
    },
    %{
      slug: "opencode",
      name: "OpenCode",
      cmd: "opencode",
      category: "AI coding agents",
      what: "An open-source terminal coding agent you can point at any model.",
      why: "Let it grind through a backlog while you supervise from a six-inch screen."
    },
    %{
      slug: "crush",
      name: "Crush",
      cmd: "crush",
      category: "AI coding agents",
      what: "Charm's glamorous AI coding agent for the terminal.",
      why: "It looks gorgeous on a phone and takes your one-word approvals from the throne."
    },
    %{
      slug: "goose",
      name: "Goose",
      cmd: "goose",
      category: "AI coding agents",
      what: "An on-machine AI agent that automates engineering tasks end to end.",
      why: "Authorize the risky step from your phone instead of sprinting back to your laptop."
    },
    %{
      slug: "cursor-agent",
      name: "Cursor CLI",
      cmd: "cursor-agent",
      category: "AI coding agents",
      what: "Cursor's headless agent that runs your coding tasks from the command line.",
      why: "Keep the agent moving from anywhere — answer its prompts the second they appear."
    },
    %{
      slug: "amp",
      name: "Amp",
      cmd: "amp",
      category: "AI coding agents",
      what: "An agentic coding tool that works across your whole codebase.",
      why: "Review its plan and unblock it on the go, no laptop required."
    },

    # ── AI on the command line ──────────────────────────────────────────────
    %{
      slug: "llm",
      name: "llm",
      cmd: "llm chat",
      category: "AI on the command line",
      what: "A CLI for prompting models and piping the results anywhere.",
      why: "Run a long generation and read it on your phone the second it finishes."
    },
    %{
      slug: "ollama",
      name: "Ollama",
      cmd: "ollama run llama3",
      category: "AI on the command line",
      what: "Run open large language models locally with a single command.",
      why:
        "Chat with your self-hosted model from the bathroom — your GPU does the sweating, not you."
    },
    %{
      slug: "sgpt",
      name: "Shell GPT",
      cmd: "sgpt --repl temp",
      category: "AI on the command line",
      what: "A command-line tool that turns prompts into shell commands and answers.",
      why: "Ask it for the command you forgot without getting up."
    },
    %{
      slug: "mods",
      name: "Mods",
      cmd: "mods",
      category: "AI on the command line",
      what: "AI for the command line that pipes model output straight into your workflow.",
      why: "Glance at the answer on your phone while the pipeline keeps flowing."
    },
    %{
      slug: "copilot",
      name: "GitHub Copilot CLI",
      cmd: "copilot",
      category: "AI on the command line",
      what: "GitHub's AI assistant for the terminal that explains and suggests commands.",
      why: "Get unstuck on a gnarly command from anywhere you happen to be sitting."
    },

    # ── Editors ─────────────────────────────────────────────────────────────
    %{
      slug: "vim",
      name: "Vim",
      cmd: "vim",
      category: "Editors",
      what: "The ubiquitous modal text editor that lives in every terminal.",
      why:
        "Fix that one typo in a config from your phone — you'll still need to remember how to quit."
    },
    %{
      slug: "nvim",
      name: "Neovim",
      cmd: "nvim",
      category: "Editors",
      what: "A hyperextensible, Lua-powered fork of Vim.",
      why: "Drive your fully-loaded IDE-in-a-terminal from the smallest screen you own."
    },
    %{
      slug: "emacs",
      name: "Emacs",
      cmd: "emacs -nw",
      category: "Editors",
      what: "The extensible, self-documenting editor that's basically an operating system.",
      why: "Check your org-agenda or run an M-x command without leaving the bathroom."
    },
    %{
      slug: "nano",
      name: "Nano",
      cmd: "nano",
      category: "Editors",
      what: "The friendly, no-modes terminal editor for quick edits.",
      why: "Make a one-line change on the go without a cheat sheet."
    },
    %{
      slug: "helix",
      name: "Helix",
      cmd: "hx",
      category: "Editors",
      what: "A post-modern modal editor with multiple selections and tree-sitter built in.",
      why: "Pop into a file and edit it from your phone with zero plugins to configure."
    },
    %{
      slug: "micro",
      name: "Micro",
      cmd: "micro",
      category: "Editors",
      what: "A modern terminal editor with mouse support and sane keybindings.",
      why: "Edit a file remotely with shortcuts your thumbs already know."
    },

    # ── Shells & multiplexers ───────────────────────────────────────────────
    %{
      slug: "tmux",
      name: "tmux",
      cmd: "tmux attach",
      category: "Shells & multiplexers",
      what: "A terminal multiplexer that keeps your sessions alive across disconnects.",
      why: "Reattach to everything you were running and check on it from the loo."
    },
    %{
      slug: "screen",
      name: "GNU Screen",
      cmd: "screen -r",
      category: "Shells & multiplexers",
      what: "The original terminal multiplexer for persistent sessions.",
      why: "Peek at a long-running job from anywhere without SSH gymnastics."
    },
    %{
      slug: "zellij",
      name: "Zellij",
      cmd: "zellij",
      category: "Shells & multiplexers",
      what: "A modern terminal workspace with panes, tabs, and layouts.",
      why: "Carry your whole workspace in your pocket and glance at any pane."
    },
    %{
      slug: "bash",
      name: "Bash",
      cmd: "bash",
      category: "Shells & multiplexers",
      what: "The shell that runs the world.",
      why: "Run one quick command on your box without opening a laptop."
    },
    %{
      slug: "zsh",
      name: "Zsh",
      cmd: "zsh",
      category: "Shells & multiplexers",
      what: "A powerful shell with great completion and a thriving plugin scene.",
      why: "Your fully-themed shell, now reachable from the bathroom."
    },
    %{
      slug: "fish",
      name: "fish",
      cmd: "fish",
      category: "Shells & multiplexers",
      what: "The friendly interactive shell with autosuggestions out of the box.",
      why: "Type a command and let fish finish it for you — from your phone."
    },
    %{
      slug: "nushell",
      name: "Nushell",
      cmd: "nu",
      category: "Shells & multiplexers",
      what: "A shell that treats your data as structured tables.",
      why: "Query a log as a table and scroll the results on your phone."
    },

    # ── Git & ops TUIs ──────────────────────────────────────────────────────
    %{
      slug: "lazygit",
      name: "Lazygit",
      cmd: "lazygit",
      category: "Git & ops TUIs",
      what: "A blazing-fast terminal UI for git.",
      why: "Stage, commit, and resolve that merge from the smallest screen in the house."
    },
    %{
      slug: "gitui",
      name: "GitUI",
      cmd: "gitui",
      category: "Git & ops TUIs",
      what: "A fast, keyboard-driven terminal UI for git, written in Rust.",
      why: "Blast through your staging area with one thumb."
    },
    %{
      slug: "tig",
      name: "tig",
      cmd: "tig",
      category: "Git & ops TUIs",
      what: "A text-mode interface for browsing git history.",
      why: "Scroll the commit log on your phone to find the change that broke things."
    },
    %{
      slug: "lazydocker",
      name: "Lazydocker",
      cmd: "lazydocker",
      category: "Git & ops TUIs",
      what: "A terminal UI for managing Docker and docker-compose.",
      why: "Restart a flailing container from anywhere — the bathroom counts as on-call."
    },
    %{
      slug: "k9s",
      name: "K9s",
      cmd: "k9s",
      category: "Git & ops TUIs",
      what: "A terminal UI to observe and manage your Kubernetes clusters.",
      why: "Watch pods and tail logs during an incident, wherever you are."
    },
    %{
      slug: "htop",
      name: "htop",
      cmd: "htop",
      category: "Git & ops TUIs",
      what: "An interactive process viewer for the terminal.",
      why: "Spot the runaway process and kill it before it eats your server — no desk required."
    },
    %{
      slug: "btop",
      name: "btop",
      cmd: "btop",
      category: "Git & ops TUIs",
      what: "A gorgeous resource monitor for CPU, memory, disk, and network.",
      why: "Keep one eye on your server's vitals from the throne."
    },
    %{
      slug: "glances",
      name: "Glances",
      cmd: "glances",
      category: "Git & ops TUIs",
      what: "A cross-platform system monitor that shows everything at a glance.",
      why: "Check your box's health on a screen that fits in your hand."
    },

    # ── REPLs & databases ───────────────────────────────────────────────────
    %{
      slug: "python",
      name: "Python REPL",
      cmd: "python",
      category: "REPLs & databases",
      what: "The interactive Python interpreter.",
      why: "Test a snippet or poke at an object from your phone."
    },
    %{
      slug: "ipython",
      name: "IPython",
      cmd: "ipython",
      category: "REPLs & databases",
      what: "A rich interactive Python shell with magic commands.",
      why: "Re-run a cell and read the output from the couch."
    },
    %{
      slug: "node",
      name: "Node.js REPL",
      cmd: "node",
      category: "REPLs & databases",
      what: "The interactive JavaScript runtime.",
      why: "Try a one-liner without opening your laptop."
    },
    %{
      slug: "irb",
      name: "IRB",
      cmd: "irb",
      category: "REPLs & databases",
      what: "Ruby's interactive console.",
      why: "Inspect an object or run a quick experiment on the go."
    },
    %{
      slug: "iex",
      name: "IEx",
      cmd: "iex",
      category: "REPLs & databases",
      what: "Elixir's interactive shell, great for poking at a running system.",
      why: "Connect to your app and run a command from anywhere."
    },
    %{
      slug: "psql",
      name: "psql",
      cmd: "psql",
      category: "REPLs & databases",
      what: "PostgreSQL's interactive terminal.",
      why: "Run that read-only query you forgot before the deploy — from your phone."
    },
    %{
      slug: "mysql",
      name: "mysql",
      cmd: "mysql",
      category: "REPLs & databases",
      what: "The MySQL command-line client.",
      why: "Check a row count without firing up a GUI."
    },
    %{
      slug: "redis-cli",
      name: "redis-cli",
      cmd: "redis-cli",
      category: "REPLs & databases",
      what: "The Redis command-line interface.",
      why: "Inspect a key or flush a cache from anywhere."
    },
    %{
      slug: "mongosh",
      name: "mongosh",
      cmd: "mongosh",
      category: "REPLs & databases",
      what: "The modern MongoDB shell.",
      why: "Run a quick find() from the smallest device you own."
    },
    %{
      slug: "sqlite3",
      name: "SQLite",
      cmd: "sqlite3 app.db",
      category: "REPLs & databases",
      what: "The SQLite command-line shell.",
      why: "Query a local database without leaving the bathroom."
    },

    # ── Infra & remote ──────────────────────────────────────────────────────
    %{
      slug: "docker",
      name: "Docker",
      cmd: "docker stats",
      category: "Infra & remote",
      what: "Build, run, and manage containers from the command line.",
      why: "Bounce a service from your phone when the pager goes off."
    },
    %{
      slug: "kubectl",
      name: "kubectl",
      cmd: "kubectl get pods -w",
      category: "Infra & remote",
      what: "The Kubernetes command-line tool.",
      why: "Scale a deployment or read events during an incident, wherever you are."
    },
    %{
      slug: "terraform",
      name: "Terraform",
      cmd: "terraform plan",
      category: "Infra & remote",
      what: "Provision and change infrastructure as code.",
      why: "Review a plan and type 'yes' to apply — from the bathroom, if you're brave."
    },
    %{
      slug: "ansible",
      name: "Ansible",
      cmd: "ansible-playbook site.yml",
      category: "Infra & remote",
      what: "Automate configuration across your fleet with playbooks.",
      why: "Kick off a playbook and watch it roll out from your phone."
    },
    %{
      slug: "ssh",
      name: "SSH",
      cmd: "ssh user@host",
      category: "Infra & remote",
      what: "The secure shell for logging into remote machines.",
      why: "Hop onto a box and run one command without your laptop."
    },
    %{
      slug: "mosh",
      name: "Mosh",
      cmd: "mosh user@host",
      category: "Infra & remote",
      what: "A resilient remote shell that survives flaky connections.",
      why: "Stay connected to your server even on bathroom Wi-Fi."
    },
    %{
      slug: "journalctl",
      name: "journalctl",
      cmd: "journalctl -f",
      category: "Infra & remote",
      what: "Query and follow systemd logs.",
      why: "Tail the logs during an outage from wherever you are."
    },
    %{
      slug: "tail",
      name: "tail -f",
      cmd: "tail -f /var/log/app.log",
      category: "Infra & remote",
      what: "Follow a log file in real time.",
      why: "Keep an eye on the logs without being at your desk."
    },
    %{
      slug: "watch",
      name: "watch",
      cmd: "watch -n1 'kubectl get pods'",
      category: "Infra & remote",
      what: "Run a command repeatedly and watch the output update.",
      why: "Babysit a number that needs to change before you can relax."
    },

    # ── File managers & fun ─────────────────────────────────────────────────
    %{
      slug: "ranger",
      name: "Ranger",
      cmd: "ranger",
      category: "File managers & fun",
      what: "A Vim-inspired terminal file manager with previews.",
      why: "Browse your files from your phone like it's a tiny Finder."
    },
    %{
      slug: "nnn",
      name: "nnn",
      cmd: "nnn",
      category: "File managers & fun",
      what: "A blazing-fast, lightweight terminal file manager.",
      why: "Find and move a file without touching a mouse."
    },
    %{
      slug: "mc",
      name: "Midnight Commander",
      cmd: "mc",
      category: "File managers & fun",
      what: "The classic two-pane terminal file manager.",
      why: "Copy files between folders from the comfort of the couch."
    },
    %{
      slug: "weechat",
      name: "WeeChat",
      cmd: "weechat",
      category: "File managers & fun",
      what: "A fast, extensible terminal chat client for IRC and more.",
      why: "Stay in the channel from your phone without a separate app."
    },
    %{
      slug: "irssi",
      name: "Irssi",
      cmd: "irssi",
      category: "File managers & fun",
      what: "The venerable terminal IRC client.",
      why: "Lurk in your favorite channels from anywhere."
    },
    %{
      slug: "neomutt",
      name: "NeoMutt",
      cmd: "neomutt",
      category: "File managers & fun",
      what: "A powerful terminal email client.",
      why: "Triage your inbox with keyboard shortcuts on a phone — ironically."
    },
    %{
      slug: "newsboat",
      name: "Newsboat",
      cmd: "newsboat",
      category: "File managers & fun",
      what: "An RSS/Atom feed reader for the terminal.",
      why: "Catch up on your feeds during a quick break."
    },
    %{
      slug: "taskwarrior",
      name: "Taskwarrior",
      cmd: "task",
      category: "File managers & fun",
      what: "A command-line to-do manager that's surprisingly powerful.",
      why: "Add the task you just thought of before you forget it."
    },
    %{
      slug: "cmus",
      name: "cmus",
      cmd: "cmus",
      category: "File managers & fun",
      what: "A small, fast terminal music player.",
      why: "Skip a track without unlocking your phone's music app."
    },
    %{
      slug: "cmatrix",
      name: "cmatrix",
      cmd: "cmatrix",
      category: "File managers & fun",
      what: "Falling green code, just like the movie.",
      why: "Look extremely busy from the bathroom. We won't tell."
    },
    %{
      slug: "cointop",
      name: "cointop",
      cmd: "cointop",
      category: "File managers & fun",
      what: "A fast terminal UI for tracking cryptocurrency prices.",
      why: "Watch the charts melt down in real time, wherever you are."
    }
  ]

  @doc "All tools, in catalog order."
  def all, do: @tools

  @doc "The ordered list of category names."
  def categories, do: @categories

  @doc "Look up a tool by slug, or `nil` if there's no such tool."
  def get(slug), do: Enum.find(@tools, &(&1.slug == slug))

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
       kubectl ssh iex python node redis-cli ollama crush ranger cmatrix cointop)
  end

  @doc "The featured tools, in `featured_slugs/0` order."
  def featured do
    Enum.map(featured_slugs(), &get/1)
  end
end
