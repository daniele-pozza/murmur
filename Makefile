EXEC     := MurmurYouTube
CONFIG   := debug

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/MurmurYouTubeBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/MurmurYouTubeBuild
APPNAME  := Murmur.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC keys the Accessibility grant to the code signature, so an ad-hoc signature — which
## changes on every build — makes the user re-grant after every `make`. Signing with a
## stable identity keeps the signature constant and the grant sticky. Prefer a real
## Developer ID if present; otherwise the `signing-identity` target creates a self-signed
## "Murmur Local Signing" cert in the login keychain (once) and we sign with that.
## `=` (recursive), not `:=`: the expression must be evaluated at USE time, after the
## `signing-identity` prerequisite has run — a parse-time `ifeq` check runs too early and
## the fallback literal below would sign ad-hoc on the first build.
SIGN_ID = $(or $(shell security find-identity -v -p codesigning 2>/dev/null \
                | grep "Developer ID Application\|Murmur Local Signing" | head -1 \
                | sed -E 's/.*"(.*)".*/\1/'), -)

.PHONY: all build app run install clean icon signing-identity

## Ensure a stable codesigning identity exists. With no Developer ID on the machine, make
## a self-signed "Murmur Local Signing" cert in the login keychain, trusted as a root so
## codesign will use it. Idempotent: does nothing once either kind of identity is present,
## and the identity is stable across rebuilds — which is exactly why the Accessibility
## grant survives `make`.
signing-identity:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application\|Murmur Local Signing"; then \
		echo "signing identity present (Developer ID or Murmur Local Signing)"; \
	else \
		KC=$$(security default-keychain | tr -d '"'); \
		TMP=$$(mktemp -d); \
		openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
			-subj "/CN=Murmur Local Signing" \
			-addext "basicConstraints=critical,CA:FALSE" \
			-addext "keyUsage=digitalSignature" \
			-addext "extendedKeyUsage=codeSigning" \
			-keyout $$TMP/signing.key.pem -out $$TMP/signing.cert.pem 2>/dev/null; \
		openssl pkcs12 -export -legacy -out $$TMP/signing.p12 \
			-inkey $$TMP/signing.key.pem -in $$TMP/signing.cert.pem \
			-passout pass:murmur -name "Murmur Local Signing" 2>/dev/null; \
		security import $$TMP/signing.p12 -k "$$KC" -P murmur -T /usr/bin/codesign -A; \
		security find-certificate -c "Murmur Local Signing" -p "$$KC" > $$TMP/real.pem; \
		security add-trusted-cert -d -r trustRoot -k "$$KC" $$TMP/real.pem; \
		rm -rf $$TMP; \
		echo "created codesigning identity: Murmur Local Signing"; \
	fi

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

## Regenerates AppIcon.icns from Tools/makeicon.swift. Not a dependency of `app` — the
## icon rarely changes and rendering 10 PNGs on every build is wasted time.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build signing-identity
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@# transcribe.cpp's CTranscribe.xcframework ships as a dynamic framework, and the
	@# executable's LC_RPATH is @loader_path (SwiftPM's own build-dir layout) — so it
	@# has to live next to the binary in Contents/MacOS, not the conventional
	@# Contents/Frameworks, or dyld fails to find it at launch.
	@cp -R "$(SCRATCH)/$(CONFIG)/CTranscribe.framework" "$(CONTENTS)/MacOS/CTranscribe.framework"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

## Only ever targets the MurmurYouTube executable — never the separate `murmur` app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Ad-hoc signatures change on every rebuild, which resets the Accessibility grant.
## Installing to /Applications keeps the path stable and makes re-granting a one-click fix.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

MODEL_DIR	:= $(HOME)/Library/Application Support/MurmurYouTube
MODEL_FILE	:= nemotron-3.5-asr-streaming-0.6b-Q5_K_M.gguf
MODEL_URL	:= https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf/resolve/main/$(MODEL_FILE)

## One-shot model fetch (~700 MB). Skips if already present; resumes partial downloads.
download-model:
	@if [ -f "$(MODEL_DIR)/$(MODEL_FILE)" ]; then echo "model already present: $(MODEL_DIR)/$(MODEL_FILE)"; \
	else mkdir -p "$(MODEL_DIR)" && curl -L -C - --fail -o "$(MODEL_DIR)/$(MODEL_FILE).part" "$(MODEL_URL)" \
	&& mv "$(MODEL_DIR)/$(MODEL_FILE).part" "$(MODEL_DIR)/$(MODEL_FILE)" \
	&& echo "model installed: $(MODEL_DIR)/$(MODEL_FILE)"; fi

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
