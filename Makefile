APP        := AiTaskbar.app
# Bundle identifier — override via env when forking:
#   make BUNDLE_ID=com.myorg.aitaskbar app
# Default points to a generic local namespace so the upstream repo doesn't
# baked in anyone's personal apple-id namespace.
BUNDLE_ID  ?= dev.aitaskbar.app
VERSION    ?= 0.1.0
BUILD_DIR  := build
APP_DIR    := $(BUILD_DIR)/$(APP)
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
	# next to the binary so Bundle.module finds them at runtime.
	-cp -R .build/release/ai-taskbar_AiTaskbarApp.bundle $(APP_DIR)/Contents/MacOS/ 2>/dev/null || true
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
	-cp -R .build/arm64-apple-macosx/release/ai-taskbar_AiTaskbarApp.bundle $(APP_DIR)/Contents/MacOS/ 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP_DIR)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" $(APP_DIR)/Contents/Info.plist
	codesign --force --deep --sign - $(APP_DIR)
	@echo "==> Built $(APP_DIR) (universal, bundle=$(BUNDLE_ID))"
	@file $(APP_DIR)/Contents/MacOS/ai-taskbar
	@lipo -archs $(APP_DIR)/Contents/MacOS/ai-taskbar

universal-check:
	@file $(APP_DIR)/Contents/MacOS/ai-taskbar
	@lipo -info $(APP_DIR)/Contents/MacOS/ai-taskbar 2>/dev/null || echo "(single-arch)"

dmg-universal: app-universal
	rm -f $(DMG)
	hdiutil create -volname "AI Taskbar" -srcfolder $(APP_DIR) -ov -format UDZO $(DMG)
	@echo "Built $(DMG) (universal)"

dmg: app
	rm -f $(DMG)
	hdiutil create -volname "AI Taskbar" -srcfolder $(APP_DIR) -ov -format UDZO $(DMG)
	@echo "Built $(DMG)"

run: app
	open $(APP_DIR)

test:
	swift test

# Full local validation — runs after EVERY implementation change.
# Compile + runtime suite + bundle + smoke launch + permission audit.
# Required by CLAUDE.md / AGENTS.md policy.
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
	rm -f $(DMG)
	hdiutil create -volname "AI Taskbar" -srcfolder $(APP_DIR) -ov -format UDZO $(DMG)
	$(MAKE) staple
	@echo "✓ Release-ready: $(DMG)"
