APP        := AiTaskbar.app
# Bundle identifier — override via env when forking:
#   make BUNDLE_ID=com.myorg.aitaskbar app
# Default points to a generic local namespace so the upstream repo doesn't
# baked in anyone's personal apple-id namespace.
BUNDLE_ID  ?= dev.aitaskbar.app
VERSION    ?= 0.10.1
BUILD_DIR  := build
APP_DIR    := $(BUILD_DIR)/$(APP)
DMG_STAGING := $(BUILD_DIR)/dmg-staging
DMG        := ai-taskbar-$(VERSION).dmg
# Apple Silicon-only DMG published alongside the universal one (half the
# size). UpdateChecker.pickDMGAsset matches on the "-arm64.dmg" suffix —
# keep the naming in sync if you ever change it.
DMG_ARM64  := ai-taskbar-$(VERSION)-arm64.dmg

.PHONY: all build app app-universal dmg dmg-universal run clean test validate \
        sign-developer sign-developer-universal dmg-signed notarize staple \
        release release-arm64 release-universal publish ship universal-check icon

all: app

build:
	swift build -c release

# Render the AppIcon.icns from the Swift script. Idempotent — safe to chain
# before every `app` build so the icon never goes stale relative to the
# source script.
icon:
	@scripts/build_icon.sh

# Default `app` target = host-architecture only. Fast for local iteration.
# For distribution use `make app-universal` (also runs on Intel Macs).
app: icon
	swift build -c release
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp .build/release/ai-taskbar $(APP_DIR)/Contents/MacOS/ai-taskbar
	cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/
	# Copy SPM-generated resource bundle (.lproj/Localizable.strings live here)
	# into Contents/Resources/. SwiftPM's generated `Bundle.module` lookup
	# tries `Bundle.main.resourceURL` first (= Contents/Resources/), so the
	# bundle MUST live there or `L10n.bundle` fatalErrors as soon as the
	# popover renders. Putting it in Contents/MacOS/ works for `swift run`
	# (where Bundle.main.bundleURL is the .build dir) but breaks the .app.
	-cp -R .build/release/ai-taskbar_AiTaskbarApp.bundle $(APP_DIR)/Contents/Resources/ 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP_DIR)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" $(APP_DIR)/Contents/Info.plist
	codesign --force --deep --sign - $(APP_DIR)
	@echo "Built $(APP_DIR) (host-arch, bundle=$(BUNDLE_ID))"
	@file $(APP_DIR)/Contents/MacOS/ai-taskbar

# Universal binary (arm64 + x86_64). Works with Command Line Tools alone —
# no full Xcode required. Strategy: build each arch separately, then `lipo`
# them into a fat binary. ~2× build time vs single-arch.
app-universal: icon
	@echo "==> Building arm64..."
	swift build -c release --arch arm64
	cp .build/arm64-apple-macosx/release/ai-taskbar build/.ai-taskbar.arm64
	@echo "==> Building x86_64..."
	swift build -c release --arch x86_64
	cp .build/x86_64-apple-macosx/release/ai-taskbar build/.ai-taskbar.x86_64
	@echo "==> lipo merging..."
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	lipo -create build/.ai-taskbar.arm64 build/.ai-taskbar.x86_64 \
		-output $(APP_DIR)/Contents/MacOS/ai-taskbar
	rm -f build/.ai-taskbar.arm64 build/.ai-taskbar.x86_64
	cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/
	# Copy resource bundle (arm64 + x86_64 ship the same resources, pick arm64).
	# Lives in Contents/Resources/ for `Bundle.module` to find it — see the
	# detailed comment on the `app` target above.
	-cp -R .build/arm64-apple-macosx/release/ai-taskbar_AiTaskbarApp.bundle $(APP_DIR)/Contents/Resources/ 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP_DIR)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" $(APP_DIR)/Contents/Info.plist
	codesign --force --deep --sign - $(APP_DIR)
	@echo "==> Built $(APP_DIR) (universal, bundle=$(BUNDLE_ID))"
	@file $(APP_DIR)/Contents/MacOS/ai-taskbar
	@lipo -archs $(APP_DIR)/Contents/MacOS/ai-taskbar

universal-check:
	@file $(APP_DIR)/Contents/MacOS/ai-taskbar
	@lipo -info $(APP_DIR)/Contents/MacOS/ai-taskbar 2>/dev/null || echo "(single-arch)"

# `make dmg-staging-src` builds a DMG staging directory containing:
#   - AiTaskbar.app
#   - /Applications symlink (so the user can drag-to-install)
#   - a fallback README.txt pointing at the project's GitHub Releases
# The DMG targets below bundle this directory rather than the .app alone,
# so the mounted image shows the standard "drag app to Applications" UX.
dmg-staging-src: app
	rm -rf $(DMG_STAGING)
	mkdir -p $(DMG_STAGING)
	cp -R $(APP_DIR) $(DMG_STAGING)/
	ln -s /Applications $(DMG_STAGING)/Applications
	@printf 'AI Taskbar v%s\n\nDrag AiTaskbar.app to the Applications folder.\nIssues: https://github.com/justoeu/ai-taskbar/issues\n' "$(VERSION)" > $(DMG_STAGING)/README.txt
	@echo "==> Staged $(DMG_STAGING)"

dmg-universal: app-universal
	rm -rf $(DMG_STAGING) $(DMG)
	mkdir -p $(DMG_STAGING)
	cp -R $(APP_DIR) $(DMG_STAGING)/
	ln -s /Applications $(DMG_STAGING)/Applications
	@printf 'AI Taskbar v%s\n\nDrag AiTaskbar.app to the Applications folder.\nIssues: https://github.com/justoeu/ai-taskbar/issues\n' "$(VERSION)" > $(DMG_STAGING)/README.txt
	hdiutil create -volname "AI Taskbar" -srcfolder $(DMG_STAGING) -ov -format UDZO $(DMG)
	rm -rf $(DMG_STAGING)
	@echo "Built $(DMG) (universal, with Applications symlink)"

dmg: app
	rm -rf $(DMG_STAGING) $(DMG)
	mkdir -p $(DMG_STAGING)
	cp -R $(APP_DIR) $(DMG_STAGING)/
	ln -s /Applications $(DMG_STAGING)/Applications
	@printf 'AI Taskbar v%s\n\nDrag AiTaskbar.app to the Applications folder.\nIssues: https://github.com/justoeu/ai-taskbar/issues\n' "$(VERSION)" > $(DMG_STAGING)/README.txt
	hdiutil create -volname "AI Taskbar" -srcfolder $(DMG_STAGING) -ov -format UDZO $(DMG)
	rm -rf $(DMG_STAGING)
	@echo "Built $(DMG) (with Applications symlink)"

run: app
	open $(APP_DIR)

test:
	swift test --no-parallel

# Line coverage on AiTaskbarCore + AiTaskbarProviders. App UI views are
# excluded — SwiftUI body coverage requires Xcode/host UI testing infra
# we deliberately don't pull in. Pass COVERAGE_FLOOR=NN to fail under
# that threshold; default is `warn-only` until we close the gap.
COVERAGE_FLOOR ?= 90
coverage:
	@scripts/coverage.sh $(COVERAGE_FLOOR)

# Full local validation — runs after EVERY implementation change.
# Compile + runtime suite + bundle + smoke launch + permission audit
# + swift test + coverage report. Required by CLAUDE.md / AGENTS.md.
validate:
	@scripts/validate.sh

clean:
	rm -rf .build $(BUILD_DIR) $(DMG) $(DMG_ARM64) checksums-*.txt .swiftpm Package.resolved

# ─── Code signing for distribution ──────────────────────────────────────────
# These targets require a paid Apple Developer ID. Without one, `make app`
# already produces an ad-hoc-signed bundle that runs locally (with Gatekeeper
# warnings on first launch).
#
# Required env vars:
#   DEVELOPER_ID         e.g. "Developer ID Application: Jane Doe (TEAM12345)"
#
# Notarization credentials — EITHER:
#   NOTARY_PROFILE       name of a keychain profile stored once via
#                        `xcrun notarytool store-credentials <name>`
#                        (preferred: the app-specific password never touches
#                        env vars or shell history)
# OR the explicit trio:
#   APPLE_ID             your Apple ID email (for notarytool)
#   APPLE_TEAM_ID        10-char team identifier
#   APPLE_PASSWORD       app-specific password from account.apple.com

sign-developer: app
ifndef DEVELOPER_ID
	$(error DEVELOPER_ID not set. Example: DEVELOPER_ID="Developer ID Application: Your Name (TEAM12345)" make sign-developer)
endif
	codesign --force --options runtime --timestamp \
		--entitlements Resources/entitlements.plist \
		--sign "$(DEVELOPER_ID)" \
		$(APP_DIR)
	codesign --verify --deep --strict --verbose=2 $(APP_DIR)
	@echo "✓ Signed $(APP_DIR) with $(DEVELOPER_ID)"

# Operates on the EXISTING $(DMG) — run `make release` to produce it.
# Deliberately NOT dependent on `dmg`: that target re-runs `make app`, whose
# ad-hoc re-sign would clobber the Developer ID signature and Apple would
# reject the submission.
notarize:
	@test -f $(DMG) || { echo "✗ $(DMG) not found — run 'make release' first (builds the Developer ID-signed DMG)"; exit 1; }
ifdef NOTARY_PROFILE
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
else
ifndef APPLE_ID
	$(error APPLE_ID not set — or set NOTARY_PROFILE=<name> stored via 'xcrun notarytool store-credentials')
endif
ifndef APPLE_TEAM_ID
	$(error APPLE_TEAM_ID not set)
endif
ifndef APPLE_PASSWORD
	$(error APPLE_PASSWORD not set — use an app-specific password from account.apple.com)
endif
	xcrun notarytool submit $(DMG) \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(APPLE_TEAM_ID)" \
		--password "$(APPLE_PASSWORD)" \
		--wait
endif
	@echo "✓ Notarized $(DMG)"

staple: notarize
	xcrun stapler staple $(DMG)
	xcrun stapler validate $(DMG)
	@echo "✓ Stapled $(DMG) — Gatekeeper will accept without warnings"

# Full release pipeline: build → sign with Developer ID → bundle DMG →
# notarize → staple. Requires all env vars above.
# Same Developer ID signing recipe as `sign-developer`, applied to the
# universal (arm64 + x86_64) bundle instead of the host-arch one.
sign-developer-universal: app-universal
ifndef DEVELOPER_ID
	$(error DEVELOPER_ID not set. Example: DEVELOPER_ID="Developer ID Application: Your Name (TEAM12345)" make sign-developer-universal)
endif
	codesign --force --options runtime --timestamp \
		--entitlements Resources/entitlements.plist \
		--sign "$(DEVELOPER_ID)" \
		$(APP_DIR)
	codesign --verify --deep --strict --verbose=2 $(APP_DIR)
	@echo "✓ Signed $(APP_DIR) (universal) with $(DEVELOPER_ID)"

# Internal: bundle the CURRENT $(APP_DIR) into $(DMG_OUT) and sign the DMG
# container itself (Apple-recommended), BEFORE notarization — any byte change
# after stapling would invalidate the ticket. Invoked via
# `$(MAKE) dmg-signed DMG_OUT=<file>` from the release targets below.
dmg-signed:
ifndef DMG_OUT
	$(error dmg-signed is internal — run 'make release' instead)
endif
	rm -rf $(DMG_STAGING) $(DMG_OUT)
	mkdir -p $(DMG_STAGING)
	cp -R $(APP_DIR) $(DMG_STAGING)/
	ln -s /Applications $(DMG_STAGING)/Applications
	@printf 'AI Taskbar v%s\n\nDrag AiTaskbar.app to the Applications folder.\nIssues: https://github.com/justoeu/ai-taskbar/issues\n' "$(VERSION)" > $(DMG_STAGING)/README.txt
	hdiutil create -volname "AI Taskbar" -srcfolder $(DMG_STAGING) -ov -format UDZO $(DMG_OUT)
	rm -rf $(DMG_STAGING)
	codesign --force --timestamp --sign "$(DEVELOPER_ID)" $(DMG_OUT)

# Apple Silicon-only DMG (host-arch build — this repo is developed on arm64).
release-arm64: sign-developer
	$(MAKE) dmg-signed DMG_OUT=$(DMG_ARM64) DEVELOPER_ID="$(DEVELOPER_ID)"
	$(MAKE) staple DMG=$(DMG_ARM64)

# Universal DMG under the canonical name (works on Intel too).
release-universal: sign-developer-universal
	$(MAKE) dmg-signed DMG_OUT=$(DMG) DEVELOPER_ID="$(DEVELOPER_ID)"
	$(MAKE) staple DMG=$(DMG)

# Both notarized DMGs. Serial on purpose: each release-* rebuilds $(APP_DIR)
# for its architecture set, so they must not interleave.
release: release-arm64 release-universal
	@echo "✓ Release-ready: $(DMG_ARM64) (Apple Silicon) + $(DMG) (universal)"

# Upload both notarized DMGs (+ checksums) to the GitHub Release for the
# current VERSION and flip it from draft to published. Guards: clean tree and
# HEAD tagged v$(VERSION), so what we notarize is exactly what the tag points
# at. CI (release.yml) creates the draft release with notes; this publishes it.
publish:
	@test -z "$$(git status --porcelain)" || { echo "✗ working tree not clean — commit or stash first"; exit 1; }
	@git tag --points-at HEAD | grep -qx "v$(VERSION)" || { echo "✗ HEAD is not tagged v$(VERSION) — pull the release bump commit + tag first"; exit 1; }
	$(MAKE) release
	shasum -a 256 $(DMG) $(DMG_ARM64) > checksums-$(VERSION).txt
	gh release upload "v$(VERSION)" $(DMG) $(DMG_ARM64) checksums-$(VERSION).txt --clobber
	gh release edit "v$(VERSION)" --draft=false
	@echo "✓ Published v$(VERSION): $(DMG_ARM64) + $(DMG) + checksums"

# One-shot release: push main → wait for CI to bump/tag/draft → pull the bump
# commit → make publish. Aborts cleanly when the head commit opted out via
# [skip release]. Same env as publish (DEVELOPER_ID + NOTARY_PROFILE/APPLE_*).
ship:
	@scripts/ship.sh
