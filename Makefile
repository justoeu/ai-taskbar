APP        := AiTaskbar.app
# Bundle identifier — override via env when forking:
#   make BUNDLE_ID=com.myorg.aitaskbar app
# Default points to a generic local namespace so the upstream repo doesn't
# baked in anyone's personal apple-id namespace.
BUNDLE_ID  ?= dev.aitaskbar.app
VERSION    ?= 0.7.2
BUILD_DIR  := build
APP_DIR    := $(BUILD_DIR)/$(APP)
DMG_STAGING := $(BUILD_DIR)/dmg-staging
DMG        := ai-taskbar-$(VERSION).dmg

.PHONY: all build app app-universal dmg dmg-universal run clean test validate \
        sign-developer notarize staple release universal-check icon

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
	rm -rf .build $(BUILD_DIR) $(DMG) .swiftpm Package.resolved

# ─── Code signing for distribution ──────────────────────────────────────────
# These targets require a paid Apple Developer ID. Without one, `make app`
# already produces an ad-hoc-signed bundle that runs locally (with Gatekeeper
# warnings on first launch).
#
# Required env vars:
#   DEVELOPER_ID         e.g. "Developer ID Application: Jane Doe (TEAM12345)"
#   APPLE_ID             your Apple ID email (for notarytool)
#   APPLE_TEAM_ID        10-char team identifier
#   APPLE_PASSWORD       app-specific password from appleid.apple.com
#                        OR use APPLE_API_KEY+APPLE_API_ISSUER+APPLE_API_KEY_PATH

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

notarize: dmg
ifndef APPLE_ID
	$(error APPLE_ID not set)
endif
ifndef APPLE_TEAM_ID
	$(error APPLE_TEAM_ID not set)
endif
ifndef APPLE_PASSWORD
	$(error APPLE_PASSWORD not set — use an app-specific password from appleid.apple.com)
endif
	xcrun notarytool submit $(DMG) \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(APPLE_TEAM_ID)" \
		--password "$(APPLE_PASSWORD)" \
		--wait
	@echo "✓ Notarized $(DMG)"

staple: notarize
	xcrun stapler staple $(DMG)
	xcrun stapler validate $(DMG)
	@echo "✓ Stapled $(DMG) — Gatekeeper will accept without warnings"

# Full release pipeline: build → sign with Developer ID → bundle DMG →
# notarize → staple. Requires all env vars above.
release: sign-developer
	rm -rf $(DMG_STAGING) $(DMG)
	mkdir -p $(DMG_STAGING)
	cp -R $(APP_DIR) $(DMG_STAGING)/
	ln -s /Applications $(DMG_STAGING)/Applications
	hdiutil create -volname "AI Taskbar" -srcfolder $(DMG_STAGING) -ov -format UDZO $(DMG)
	rm -rf $(DMG_STAGING)
	$(MAKE) staple
	@echo "✓ Release-ready: $(DMG)"
