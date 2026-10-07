# Convenience targets. Everything here is a thin wrapper around swift / scripts/.
#
#   make                 # debug build
#   make test            # unit tests + live tests against headsetcontrol --test-device
#   make check           # warning-free build, tests, String Catalog up to date
#   make app             # dist/Hushdeck.app
#   make release         # dist/Hushdeck-<VERSION>.zip, .sha256 and a filled-in cask
#   make release VERSION=0.2.0
#   make strings         # sync Localizable.xcstrings with the code
#   make run             # run from source against the test device

VERSION ?= 0.1.0

.PHONY: build test check app release strings run clean

build:
	swift build

test:
	swift test

check:
	swift build --build-tests -Xswiftc -warnings-as-errors
	swift test
	scripts/sync-strings.sh --check

app:
	HUSHDECK_VERSION=$(VERSION) scripts/build-app.sh

release:
	HUSHDECK_VERSION=$(VERSION) scripts/package-release.sh

strings:
	scripts/sync-strings.sh

run:
	HUSHDECK_TEST_DEVICE=1 swift run Hushdeck

clean:
	rm -rf .build dist
