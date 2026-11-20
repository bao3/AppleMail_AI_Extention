SHELL := /bin/zsh
PROJECT := AppleMailAI.xcodeproj
SCHEME := AppleMailAI
TEST_SCHEME := AppleMailAITests
DERIVED := build/DerivedData
RELEASE_APP := $(DERIVED)/Build/Products/Release/AppleMailAI.app
DEBUG_APP := $(DERIVED)/Build/Products/Debug/AppleMailAI.app
INSTALL_DIR ?= $(HOME)/Applications
INSTALLED_APP := $(INSTALL_DIR)/AppleMailAI.app
INSTALLED_APPEX := $(INSTALLED_APP)/Contents/PlugIns/MailAIExtension.appex
EXT_BUNDLE_ID := com.bao3.AppleMailAI.Extension

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
	rm -rf "$(INSTALLED_APP)"
	ditto "$(RELEASE_APP)" "$(INSTALLED_APP)"
	$(MAKE) reset-pluginkit

reset-pluginkit:
	# Unregister stale DerivedData copies so Apple Mail only ever loads the installed appex
	pluginkit -r "$(CURDIR)/$(RELEASE_APP)/Contents/PlugIns/MailAIExtension.appex" 2>/dev/null || true
	pluginkit -r "$(CURDIR)/$(DEBUG_APP)/Contents/PlugIns/MailAIExtension.appex" 2>/dev/null || true
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
	log stream --style compact --predicate 'subsystem == "com.bao3.AppleMailAI" OR process == "MailAIExtension"' --level debug

clean:
	rm -rf build
