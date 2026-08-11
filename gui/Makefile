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

.PHONY: all build bundle sign run install clean identity check

all: sign

build:
	swift build -c $(CONFIG)

bundle: build
	@rm -rf "$(APP_DIR)"
	@mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	@cp "$(BIN)" "$(APP_DIR)/Contents/MacOS/NetdiagGUI"
	@cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP_DIR)/Contents/PkgInfo"
	@echo "bundled: $(APP_DIR)"

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

# Report what the app will actually find at runtime. The CLI is normally a
# symlink that re-execs under Homebrew bash, so a wrong PATH breaks it in a
# way that only shows up as an empty dashboard.
check:
	@echo "swift:     $$(swift --version 2>&1 | head -1)"
	@echo "identity:  $${SIGN_IDENTITY:-<none — will sign ad-hoc>}"
	@printf 'netdiag:   '; \
	  found=''; \
	  for p in "$$HOME/bin/netdiag" /opt/homebrew/bin/netdiag /usr/local/bin/netdiag \
	           "$$HOME/Documents/AI-Workspace/netdiag/bin/netdiag"; do \
	    [ -x "$$p" ] && { found="$$p"; break; }; \
	  done; \
	  echo "$${found:-<not found — set a path in Settings>}"

clean:
	swift package clean
	rm -rf "$(BUILD_DIR)"
