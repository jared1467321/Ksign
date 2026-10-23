NAME := Asign
PLATFORM := iphoneos
SCHEMES := Asign
# Name of the built .app bundle and the produced .ipa.
# Must match PRODUCT_NAME in Asign.xcodeproj/project.pbxproj.
OUTPUT_NAME := Asign
# Build output goes to $(TMPDIR)/Asign by default.
# CI can set DERIVED_DATA to a stable path so it can be cached
# between runs, e.g. `DERIVED_DATA=$PWD/DerivedData make`.
TMP := $(if $(DERIVED_DATA),$(DERIVED_DATA),$(TMPDIR)/$(NAME))
STAGE := $(TMP)/stage
APP := $(TMP)/Build/Products/Release-$(PLATFORM)

.PHONY: all clean deps native patch-native $(SCHEMES)

all: $(SCHEMES)

clean:
	rm -rf "$(TMP)"
	rm -rf packages
	rm -rf Payload

deps:
	rm -rf deps
	mkdir -p deps
	python3 .github/scripts/fetch_backloop_certs.py deps

patch-native:
	python3 .github/scripts/prepare_ipa_patch_lief.py --target ios

native: patch-native
	python3 .github/scripts/build_device_native.py
	python3 .github/scripts/patch_idevicekit.py

$(SCHEMES): native deps
	xcodebuild \
	    -project Asign.xcodeproj \
	    -scheme "$@" \
	    -configuration Release \
	    -arch arm64 \
	    -sdk $(PLATFORM) \
	    -derivedDataPath $(TMP) \
	    -skipPackagePluginValidation \
	    CODE_SIGNING_ALLOWED=NO \
	    ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	python3 .github/scripts/package_ipa.py --app "$(APP)/$(OUTPUT_NAME).app" --output packages
