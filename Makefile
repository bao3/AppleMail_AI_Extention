SHELL := /bin/zsh
PROJECT := MailKBAI.xcodeproj
SCHEME := MailKBAI
TEST_SCHEME := MailKBAITests
DERIVED := build/DerivedData
RELEASE_APP := $(DERIVED)/Build/Products/Release/MailKBAI.app
DEBUG_APP := $(DERIVED)/Build/Products/Debug/MailKBAI.app
INSTALL_DIR ?= $(HOME)/Applications
INSTALLED_APP := $(INSTALL_DIR)/MailKBAI.app
INSTALLED_APPEX := $(INSTALLED_APP)/Contents/PlugIns/MailKBAIExtension.appex
EXT_BUNDLE_ID := com.bao3.MailKBAI.Extension
LEGACY_APP := $(INSTALL_DIR)/AppleMailAI.app
LEGACY_EXT_BUNDLE_ID := com.bao3.AppleMailAI.Extension

.PHONY: generate build build-debug test provision-key install reset-pluginkit verify-sign diagnose logs clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build

build-debug: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) build

test: generate
	xcodebuild -project $(PROJECT) -scheme $(TEST_SCHEME) -derivedDataPath $(DERIVED) test

provision-key:
	./Scripts/sync_gcloud_key_to_keychain.sh

install: build
	mkdir -p "$(INSTALL_DIR)"
	osascript -e 'tell application "AppleMailAI" to quit' >/dev/null 2>&1 || true
	osascript -e 'tell application "MailKBAI" to quit' >/dev/null 2>&1 || true
	if [ -d "$(LEGACY_APP)" ]; then \
		pluginkit -r "$(LEGACY_APP)/Contents/PlugIns/MailAIExtension.appex" 2>/dev/null || true; \
		rm -rf "$(LEGACY_APP)"; \
	fi
	rm -rf "$(INSTALLED_APP)"
	ditto "$(RELEASE_APP)" "$(INSTALLED_APP)"
	$(MAKE) reset-pluginkit
	for legacy_group in "$(HOME)/Library/Group Containers/"*".com.bao3.AppleMailAI"; do \
		if [ -d "$$legacy_group" ]; then \
			team_prefix="$${legacy_group##*/}"; \
			team_prefix="$${team_prefix%.com.bao3.AppleMailAI}"; \
			new_group_id="$${team_prefix}.com.bao3.MailKBAI"; \
			new_group="$(HOME)/Library/Group Containers/$${new_group_id}"; \
			if [ ! -f "$$new_group/.com.apple.containermanagerd.metadata.plist" ]; then \
				open -g -j "$(INSTALLED_APP)" >/dev/null 2>&1 || true; \
				sleep 2; \
				osascript -e 'tell application "MailKBAI" to quit' >/dev/null 2>&1 || true; \
			fi; \
			if [ -f "$$new_group/.com.apple.containermanagerd.metadata.plist" ]; then \
				legacy_plist="$$legacy_group/Library/Preferences/$${team_prefix}.com.bao3.AppleMailAI.plist"; \
				new_plist="$$new_group/Library/Preferences/$${new_group_id}.plist"; \
				if [ -f "$$legacy_plist" ] && ! defaults read "$$new_plist" com.bao3.MailKBAI.migratedFromLegacyGroup.v1 >/dev/null 2>&1; then \
					defaults import "$$new_plist" "$$legacy_plist" 2>/dev/null || true; \
					defaults write "$$new_plist" com.bao3.MailKBAI.migratedFromLegacyGroup.v1 -bool true; \
				fi; \
				if [ -d "$$legacy_group/Library/Application Support/AppleMailAI/MessageCache" ]; then \
					mkdir -p "$$new_group/Library/Application Support/MailKBAI/MessageCache"; \
					rsync -a --ignore-existing "$$legacy_group/Library/Application Support/AppleMailAI/MessageCache/" "$$new_group/Library/Application Support/MailKBAI/MessageCache/" 2>/dev/null || true; \
				fi; \
			fi; \
		fi; \
	done

reset-pluginkit:
	# Unregister any stale MailKBAIExtension.appex or legacy MailAIExtension.appex registrations
	pluginkit -r "$(CURDIR)/$(RELEASE_APP)/Contents/PlugIns/MailKBAIExtension.appex" 2>/dev/null || true
	pluginkit -r "$(CURDIR)/$(DEBUG_APP)/Contents/PlugIns/MailKBAIExtension.appex" 2>/dev/null || true
	pluginkit -m -v -A -D -i "$(LEGACY_EXT_BUNDLE_ID)" 2>/dev/null | awk -F'\t' '/\.appex$$/ { print $$NF }' | while IFS= read -r legacy_path; do \
		if [ -n "$$legacy_path" ]; then \
			pluginkit -r "$$legacy_path" 2>/dev/null || true; \
		fi; \
	done
	pluginkit -m -v -A -D -i "$(EXT_BUNDLE_ID)" 2>/dev/null | awk -F'\t' '/MailKBAIExtension\.appex$$/ { print $$NF }' | while IFS= read -r stale_path; do \
		if [ -n "$$stale_path" ] && [ "$$stale_path" != "$(INSTALLED_APPEX)" ]; then \
			pluginkit -r "$$stale_path" 2>/dev/null || true; \
		fi; \
	done
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "$(INSTALLED_APP)"
	pluginkit -a "$(INSTALLED_APPEX)" || true
	pluginkit -m -v -A -D -i "$(EXT_BUNDLE_ID)" || true

verify-sign:
	codesign --verify --deep --strict --verbose=2 "$(INSTALLED_APP)"
	codesign -dvvv --entitlements - "$(INSTALLED_APP)"
	codesign -dvvv --entitlements - "$(INSTALLED_APPEX)"

diagnose:
	./Scripts/diagnose_mail_extension.sh

logs:
	log stream --style compact --predicate 'subsystem == "com.bao3.MailKBAI" OR process == "MailKBAIExtension"' --level debug

clean:
	rm -rf build
