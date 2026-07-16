PREFIX ?= /usr/local
BINARY := lyra-dynamic-wallpaper

.PHONY: build test install uninstall clean

build: ## Build the release binary
	swift build -c release

test: ## Run tests
	swift test

install: build ## Install into $(PREFIX)/bin
	install -d "$(PREFIX)/bin"
	install "$$(swift build -c release --show-bin-path)/$(BINARY)" "$(PREFIX)/bin/"

uninstall: ## Remove the installed binary
	rm -f "$(PREFIX)/bin/$(BINARY)"

clean: ## Remove build artifacts
	rm -rf .build
