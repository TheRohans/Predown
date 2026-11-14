# Convenience wrapper around CMake + xcodebuild. Run on the Mac.
#
#   make project   generate build/Predown.xcodeproj
#   make open      generate and open it in Xcode (sign + Archive from there)
#   make build     command-line Release build (signed to run locally unless a team is set)
#
# Set your team once with `make project TEAM=XXXXXXXXXX` (or export PREDOWN_TEAM_ID);
# CMake remembers it, so later runs don't need it.
#   make install   build, copy to /Applications, register the Quick Look extension
#   make preview FILE=README.md   try the Quick Look extension from the terminal

BUILD   ?= build
TEAM    ?=
APP     := $(BUILD)/Release/Predown.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: project open build install preview clean

project:
	cmake -G Xcode -B $(BUILD) $(if $(TEAM),-DPREDOWN_TEAM_ID=$(TEAM))

open: project
	open $(BUILD)/Predown.xcodeproj

build: project
	@team=$$(sed -n 's/^PREDOWN_TEAM_ID:STRING=//p' $(BUILD)/CMakeCache.txt); \
	if [ -n "$$team" ]; then sign=""; else sign="CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="; fi; \
	xcodebuild -project $(BUILD)/Predown.xcodeproj -scheme Predown -configuration Release $$sign build

install: build
	rm -rf /Applications/Predown.app
	ditto "$(APP)" /Applications/Predown.app
	$(LSREGISTER) -f -R /Applications/Predown.app
	pluginkit -a /Applications/Predown.app/Contents/PlugIns/PredownQuickLook.appex
	qlmanage -r
	qlmanage -r cache
	@echo "Installed. Open Predown once, then try: make preview FILE=README.md"

preview:
	qlmanage -p "$(FILE)"

clean:
	rm -rf $(BUILD)
