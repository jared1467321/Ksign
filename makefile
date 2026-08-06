NAME := Ksign
PLATFORM := iphoneos
SCHEMES := Ksign
# Name of the built .app bundle and the produced .ipa. Kept separate from
# SCHEMES so the Xcode scheme/target can stay "Ksign" while the output is
# renamed. Must match PRODUCT_NAME in Ksign.xcodeproj/project.pbxproj.
OUTPUT_NAME := ASign
# Build output goes to $(TMPDIR)/Ksign by default (unchanged for local
# builds). CI can set DERIVED_DATA to a stable path so it can be cached
# between runs, e.g. `DERIVED_DATA=$PWD/DerivedData make`.
TMP := $(if $(DERIVED_DATA),$(DERIVED_DATA),$(TMPDIR)/$(NAME))
STAGE := $(TMP)/stage
APP := $(TMP)/Build/Products/Release-$(PLATFORM)

.PHONY: all clean deps $(SCHEMES)

all: $(SCHEMES)

clean:
	rm -rf "$(TMP)"
	rm -rf packages
	rm -rf Payload

deps:
	rm -rf deps
	mkdir -p deps
	python3 .github/scripts/fetch_backloop_certs.py deps

$(SCHEMES): deps
	xcodebuild \
	    -project Ksign.xcodeproj \
	    -scheme "$@" \
	    -configuration Release \
	    -arch arm64 \
	    -sdk $(PLATFORM) \
	    -derivedDataPath $(TMP) \
	    -skipPackagePluginValidation \
	    CODE_SIGNING_ALLOWED=NO \
	    ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	rm -rf Payload
	rm -rf "$(STAGE)/"
	mkdir -p "$(STAGE)/Payload"

	mv "$(APP)/$(OUTPUT_NAME).app" "$(STAGE)/Payload/$(OUTPUT_NAME).app"

	chmod -R 0755 "$(STAGE)/Payload/$(OUTPUT_NAME).app"

	# Nested code first. `codesign` does not sign embedded bundles for you, and
	# an .appex left with a stale or missing signature is a common reason a
	# sideloader rejects the whole IPA. The `|| true` keeps builds working if
	# there is no PlugIns directory.
	codesign --force --sign - --timestamp=none "$(STAGE)/Payload/$(OUTPUT_NAME).app/PlugIns/"*.appex 2>/dev/null || true
	codesign --force --sign - --timestamp=none "$(STAGE)/Payload/$(OUTPUT_NAME).app"

	cp deps/* "$(STAGE)/Payload/$(OUTPUT_NAME).app/" || true

	rm -rf "$(STAGE)/Payload/$(OUTPUT_NAME).app/_CodeSignature"
	rm -rf "$(STAGE)/Payload/$(OUTPUT_NAME).app/PlugIns/"*.appex/_CodeSignature 2>/dev/null || true
	ln -sf "$(STAGE)/Payload" Payload
	
	mkdir -p packages
	zip -r9 "packages/$(OUTPUT_NAME).ipa" Payload