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

.PHONY: all clean deps native $(SCHEMES)

all: $(SCHEMES)

clean:
	rm -rf "$(TMP)"
	rm -rf packages
	rm -rf Payload

deps:
	rm -rf deps
	mkdir -p deps
	python3 .github/scripts/fetch_backloop_certs.py deps

native:
	python3 .github/scripts/build_device_native.py
	python3 .github/scripts/patch_idevicekit.py

$(SCHEMES): native deps
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

	python3 .github/scripts/package_ipa.py --app "$(APP)/$(OUTPUT_NAME).app" --output packages
