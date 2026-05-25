.PHONY: build clean report dry-run package help

help:
	@echo "Usage: make [target] [args]"
	@echo ""
	@echo "Targets:"
	@echo "  build [args]    Run the builder (default if you just say 'make')"
	@echo "  dry-run         Print build plan + dependency graph only"
	@echo "  report          Regenerate reports without building"
	@echo "  package         Regenerate dist/Package.swift from current dist/"
	@echo "  clean           Remove build/ dist/ .build/"
	@echo "  help            This message"
	@echo ""
	@echo "Examples:"
	@echo "  make build platform=macos only=openssl"
	@echo "  make build force=all"
	@echo "  make build extra-ffmpeg=\"--enable-libfdk-aac --enable-nonfree\""

build:
	swift run --package-path . MPVKitBuilder build $(filter-out $@,$(MAKECMDGOALS)) $(MAKEFLAGS)

dry-run:
	swift run --package-path . MPVKitBuilder dry-run $(filter-out $@,$(MAKECMDGOALS)) $(MAKEFLAGS)

report:
	swift run --package-path . MPVKitBuilder report $(filter-out $@,$(MAKECMDGOALS)) $(MAKEFLAGS)

package:
	swift run --package-path . MPVKitBuilder package $(filter-out $@,$(MAKECMDGOALS)) $(MAKEFLAGS)

clean:
	@rm -rf build dist
	@rm -rf .build/checkouts .build/repositories .build/artifacts
	@rm -rf .build/reports
	@rm -f  .build/state.json
	@echo "Cleaned build/ dist/ .build/reports/ .build/state.json"

# Swallow extra args like 'platform=macos' so make doesn't try to build a target for them.
%:
	@:
