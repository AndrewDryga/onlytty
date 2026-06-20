# relay — see README.md.  `make check` is the gate (what CI runs).
.DEFAULT_GOAL := help

VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.version=$(VERSION)

build: ## Build the relay runner binary to ./relay
	@go build -trimpath -ldflags "$(LDFLAGS)" -o relay .

install: ## Build + install the runner to ~/.local/bin/relay
	@go build -trimpath -ldflags "$(LDFLAGS)" -o "$(HOME)/.local/bin/relay" .
	@echo "installed $(HOME)/.local/bin/relay ($(VERSION))"

runner-check: ## Runner: gofmt + vet + tests
	@gofmt -l . | (! grep .) || { echo "gofmt: run gofmt -w ."; exit 1; }
	@go vet ./...
	@go test ./...

web-check: ## Web viewer: Node interop + unit tests
	@node --test test/web/*.test.js

server-check: ## Relay server: format check + warnings-as-errors + tests
	@cd server && mix format --check-formatted && mix compile --warnings-as-errors && mix test

check: runner-check web-check server-check ## Full gate: runner + web + server

e2e: ## Boot the relay and run the end-to-end test (runner ↔ relay ↔ viewer)
	@bash scripts/e2e.sh

clean: ## Remove build artifacts
	@rm -f relay
	@rm -rf dist

help: ## List targets
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## / — /' | sort

.PHONY: build install runner-check web-check server-check check e2e clean help
