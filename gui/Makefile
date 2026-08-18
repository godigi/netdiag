# gui/Makefile — build, bundle, sign, run.
#
# There is no Xcode on this machine, so nothing here is automatic: SwiftPM
# produces a bare Mach-O executable and the .app around it is assembled by
# hand. `make run` is the dev loop that stands in for previews.
#
#   make            build + bundle + sign
#   make run        …and launch the bundle
#   make identity   create the stable signing identity (once, interactive)
#   make install    copy the bundle to /Applications
#   make clean

APP           := Netdiag
BUNDLE_ID     := me.brianfreeman.netdiag
BUILD_DIR     := build
APP_DIR       := $(BUILD_DIR)/$(APP).app
CONFIG        := release
BIN           := .build/$(CONFIG)/NetdiagGUI
CLI_DIR       := $(APP_DIR)/Contents/Resources/cli

# The single source of truth for the shipped version is the CLI's own
# NETDIAG_VERSION (../bin/netdiag) — see the T7 note on Resources/Info.plist
# for why the plist itself never carries a real number.
# [^"]* rather than .*: a greedy match would swallow a trailing comment
# after the closing quote into the version string; head -1 guards the
# (never-expected) second matching line.
VERSION       := $(shell sed -n 's/^NETDIAG_VERSION="\([^"]*\)".*/\1/p' ../bin/netdiag | head -1)

# ── Signing ─────────────────────────────────────────────────────────────
# TCC keys its grants on bundle id *and* code signature. `codesign -s -`
# produces an ad-hoc signature whose cdhash changes on every rebuild, so
# every rebuild would re-prompt — not only for Location, which is optional,
# but for Notifications, which the entire alert engine depends on. A user
# who has to re-authorise notifications after each build stops authorising
# them.
#
# So: use a stable self-signed identity if one exists, and fall back to
# ad-hoc with a loud warning rather than failing the build.
IDENTITY_NAME := netdiag-dev
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null \
                   | grep -F '"$(IDENTITY_NAME)"' | head -1 | awk '{print $$2}')

.PHONY: all build bundle sign run install clean identity check test

all: sign

build:
	swift build -c $(CONFIG)

# This CLT-only toolchain (no Xcode.app) ships Testing.framework outside the
# default search path swift test uses — see
# gui/Sources/NetdiagGUI/Support/LenientDecoding.swift's sibling test-target
# comment, gui/Tests/NetdiagGUITests/NetworkEventTests.swift, for the
# XCTest-vs-Swift-Testing context this works around. Pass the extra -F only
# when that framework actually exists, so the target still works unmodified
# on a machine with Xcode installed.
CLT_TESTING_FRAMEWORK := /Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework

test:
	@if [ -d "$(CLT_TESTING_FRAMEWORK)" ]; then \
	  swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks; \
	else \
	  swift test; \
	fi

bundle: build
	@if [ -z "$(VERSION)" ]; then \
	  echo "error: could not read NETDIAG_VERSION from ../bin/netdiag" >&2; exit 1; \
	fi
	@rm -rf "$(APP_DIR)"
	@mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	@cp "$(BIN)" "$(APP_DIR)/Contents/MacOS/NetdiagGUI"
	@cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP_DIR)/Contents/PkgInfo"
	@# Bundle the CLI itself, so app+CLI ship — and version — as one
	@# artifact. Only bin/ lib/ helpers/ are needed at runtime (no tests/);
	@# cp -R preserves file modes (bin/netdiag stays executable; lib/*.sh
	@# stay 644 — they are sourced, never executed), and
	@# preserves the sibling bin/../lib, bin/../helpers layout that
	@# bin/netdiag's _resolve_path walk depends on to find them once
	@# symlinked or copied elsewhere.
	@mkdir -p "$(CLI_DIR)"
	@cp -R ../bin "$(CLI_DIR)/bin"
	@cp -R ../lib "$(CLI_DIR)/lib"
	@cp -R ../helpers "$(CLI_DIR)/helpers"
	@find "$(CLI_DIR)" \( -name '.DS_Store' -o -name '*.pyc' \) -delete
	@find "$(CLI_DIR)" -type d -name '__pycache__' -exec rm -rf {} +
	@# Stamp the CLI's version into the *copied* plist, never the committed
	@# template in Resources/Info.plist — see that file's comment.
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
	  "$(APP_DIR)/Contents/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" \
	  "$(APP_DIR)/Contents/Info.plist"
	@echo "bundled: $(APP_DIR) (netdiag $(VERSION))"

sign: bundle
ifeq ($(strip $(SIGN_IDENTITY)),)
	@echo "──────────────────────────────────────────────────────────────"
	@echo "  No '$(IDENTITY_NAME)' signing identity found — signing ad-hoc."
	@echo "  Every rebuild will change the code signature, which makes"
	@echo "  macOS forget the Notification and Location grants. Run"
	@echo "  'make identity' once to fix that permanently."
	@echo "──────────────────────────────────────────────────────────────"
	@codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(APP_DIR)"
else
	@codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" \
	          --options runtime --timestamp=none "$(APP_DIR)"
	@echo "signed with stable identity $(IDENTITY_NAME) ($(SIGN_IDENTITY))"
endif
	@codesign --verify --verbose=1 "$(APP_DIR)" 2>&1 | sed 's/^/  /'

# Launch the *bundle*, never .build/release/NetdiagGUI directly:
# UNUserNotificationCenter refuses to register for a process with no bundle
# identity, so the bare executable can't request the permission the alert
# engine is built on — it fails at runtime rather than at launch, which is
# worse.
run: sign
	@pkill -x NetdiagGUI 2>/dev/null || true
	open "$(APP_DIR)"
	@echo "launched. logs: log stream --predicate 'subsystem == \"$(BUNDLE_ID)\"'"

install: sign
	@rm -rf "/Applications/$(APP).app"
	@cp -R "$(APP_DIR)" /Applications/
	@echo "installed: /Applications/$(APP).app"

# One-time, and interactive: macOS will show a keychain dialog to authorise
# the trust setting. It cannot be done headlessly, which is why it is a
# separate target rather than part of the build.
identity:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -qF '"$(IDENTITY_NAME)"'; then \
	  echo "identity '$(IDENTITY_NAME)' already exists — nothing to do."; \
	else \
	  set -e; \
	  tmp="$$(mktemp -d)"; \
	  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
	    -keyout "$$tmp/key.pem" -out "$$tmp/cert.pem" \
	    -subj "/CN=$(IDENTITY_NAME)" \
	    -addext "basicConstraints=critical,CA:false" \
	    -addext "keyUsage=critical,digitalSignature" \
	    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null; \
	  openssl pkcs12 -export -legacy -out "$$tmp/id.p12" \
	    -inkey "$$tmp/key.pem" -in "$$tmp/cert.pem" -passout pass: 2>/dev/null; \
	  security import "$$tmp/id.p12" -k "$$HOME/Library/Keychains/login.keychain-db" \
	    -P "" -T /usr/bin/codesign -A; \
	  echo; \
	  echo "Imported. macOS will now ask you to authorise trusting it for"; \
	  echo "code signing — this is the step that keeps your Notification"; \
	  echo "and Location grants alive across rebuilds."; \
	  security add-trusted-cert -r trustRoot -p codeSign \
	    -k "$$HOME/Library/Keychains/login.keychain-db" "$$tmp/cert.pem"; \
	  rm -rf "$$tmp"; \
	  echo "done — re-run 'make' and the bundle will be signed stably."; \
	fi

# Report what the app will actually find at runtime. Since T7, the app
# bundles its own CLI copy (see `bundle`), so the number that matters is
# the bundled binary's own --version — not a PATH search, which the
# bundled copy makes a fallback rather than the primary path.
check:
	@echo "swift:     $$(swift --version 2>&1 | head -1)"
	@echo "identity:  $${SIGN_IDENTITY:-<none — will sign ad-hoc>}"
	@echo "cli source: ../bin/netdiag ($(VERSION))"
	@printf 'bundled:   '; \
	  cli="$(CLI_DIR)/bin/netdiag"; \
	  if [ -x "$$cli" ]; then \
	    echo "$$cli ($$("$$cli" --version 2>/dev/null))"; \
	  else \
	    echo "<not bundled yet — run 'make bundle'>"; \
	  fi

clean:
	swift package clean
	rm -rf "$(BUILD_DIR)"
