.PHONY: setup lint test wipe-sample check-privacy convert-screenshots help

help:
	@echo "RememberMe — development targets"
	@echo ""
	@echo "  make setup               install git hooks (+ optional brew installs of swiftformat, swiftlint)"
	@echo "  make lint                run swiftformat and swiftlint in lint mode"
	@echo "  make test                run swift test in every local package"
	@echo "  make wipe-sample         delete everything under sample-data/ (except README)"
	@echo "  make check-privacy       grep working tree for forbidden patterns (real personal data)"
	@echo "  make convert-screenshots HEIC → PNG into docs/ui/screenshots/"

setup:
	git config core.hooksPath .githooks
	@echo "git hooks → .githooks/"
	@command -v swiftformat >/dev/null 2>&1 || echo "(optional) brew install swiftformat"
	@command -v swiftlint   >/dev/null 2>&1 || echo "(optional) brew install swiftlint"

lint:
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat --lint .; \
	else \
		echo "swiftformat not installed, skipping"; \
	fi
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint; \
	else \
		echo "swiftlint not installed, skipping"; \
	fi

test:
	swift test --package-path Packages/Core
	swift test --package-path Packages/Persistence

wipe-sample:
	@find sample-data -mindepth 1 ! -name 'README.md' -delete
	@echo "sample-data/ reset (README kept)"

check-privacy:
	@bash scripts/check-privacy.sh

convert-screenshots:
	@bash scripts/convert-screenshots.sh
