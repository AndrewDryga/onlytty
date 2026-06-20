# relay — see README.md.  `make check` is the gate (what CI runs).
.DEFAULT_GOAL := help

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.version=$(VERSION)

build: ## Build the runner binary to ./onlytty
	@go build -trimpath -ldflags "$(LDFLAGS)" -o onlytty ./runner

install: ## Build + install the runner to ~/.local/bin/onlytty
	@go build -trimpath -ldflags "$(LDFLAGS)" -o "$(HOME)/.local/bin/onlytty" ./runner
	@echo "installed $(HOME)/.local/bin/onlytty ($(VERSION))"

runner-check: ## Runner: gofmt + vet + tests
	@gofmt -l runner | (! grep .) || { echo "gofmt: run gofmt -w runner"; exit 1; }
	@cd runner && go vet ./... && go test ./...

web-check: ## Web viewer: Node interop + unit tests
	@node --test test/web/*.test.js

server-check: ## Relay server: format check + warnings-as-errors + tests
	@cd portal && mix format --check-formatted && mix compile --warnings-as-errors && mix test

check: runner-check web-check server-check ## Full gate: runner + web + server

e2e: ## Boot the relay and run the end-to-end test (runner ↔ relay ↔ viewer)
	@bash scripts/e2e.sh

audit: audit-go audit-web audit-server ## Security audit (opt-in; not in `check`): Go vulns + npm + Hex

audit-go: ## Audit: Go vulnerabilities (needs govulncheck)
	@command -v govulncheck >/dev/null 2>&1 || { echo "install: go install golang.org/x/vuln/cmd/govulncheck@latest"; exit 1; }
	@govulncheck ./...

audit-web: ## Audit: npm advisories (high+)
	@npm audit --audit-level=high

audit-server: ## Audit: retired/withdrawn Hex packages
	@cd portal && mix hex.audit

SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo 'shasum -a 256')
viewer-hash: ## SHA-256 of each viewer asset (reproducible — publish with each release)
	@cd portal/priv/static && $(SHA256) \
	  viewer.html \
	  assets/app.js assets/crypto.js assets/wire.js \
	  assets/vendor/xterm.js assets/vendor/xterm.css assets/vendor/addon-fit.js

fuzz: ## Fuzz the protocol decoders (override length: make fuzz FUZZTIME=2m)
	@t=$${FUZZTIME:-15s}; \
	for fn in FuzzDecodeHello FuzzDecodeResize FuzzDecodeExit FuzzCipherOpen; do \
	  echo "== $$fn ($$t) =="; \
	  (cd runner && go test ./internal/protocol/ -run '^$$' -fuzz "^$$fn$$" -fuzztime="$$t") || exit 1; \
	done

load: ## Load-test session creation against a running relay (ONLYTTY_SERVER, args: N CONC)
	@bash scripts/load.sh

deploy-check: ## Pre-deploy: build+boot the prod image behind Caddy, smoke + e2e + cross-build (needs Docker)
	@bash scripts/deploy-check.sh

doctor: ## Check required toolchains; print install hints for anything missing
	@missing=0; \
	for t in go gofmt elixir mix node npm; do \
	  command -v $$t >/dev/null 2>&1 && echo "  ok       $$t" || { echo "  MISSING  $$t"; missing=1; }; \
	done; \
	[ -d node_modules/playwright ] && echo "  ok       playwright" || { echo "  MISSING  playwright (run: npm install)"; missing=1; }; \
	echo "  note     e2e browsers: npx playwright install chromium  (Linux also: npx playwright install-deps)"; \
	echo "  note     toolchain versions are pinned in .tool-versions"; \
	[ $$missing -eq 0 ] && echo "doctor: all good" || { echo "doctor: install the missing tools above"; exit 1; }

clean: ## Remove build artifacts
	@rm -f onlytty
	@rm -rf dist

help: ## List targets
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## / — /' | sort

.PHONY: build install runner-check web-check server-check check e2e deploy-check audit audit-go audit-web audit-server viewer-hash fuzz load doctor clean help
