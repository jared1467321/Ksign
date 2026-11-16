NAME := Asign
PLATFORM := iphoneos
SCHEMES := Asign
# Name of the built .app bundle and the produced .ipa.
# Must match PRODUCT_NAME in Asign.xcodeproj/project.pbxproj.
OUTPUT_NAME := Asign
BUNDLE_ID ?= AppAssassin.signer.ipa
# Build output goes to $(TMPDIR)/Asign by default.
# CI can set DERIVED_DATA to a stable path so it can be cached
# between runs, e.g. `DERIVED_DATA=$PWD/DerivedData make`.
TMP = $(if $(DERIVED_DATA),$(DERIVED_DATA),$(TMPDIR)/$(NAME))
STAGE = $(TMP)/stage
APP = $(TMP)/Build/Products/Release-$(PLATFORM)

.PHONY: all clean deps native patch-native cached $(SCHEMES)

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

# Reuse prepared dependencies and keep different identities in separate folders.
cached: DERIVED_DATA ?= $(CURDIR)/.build/xcode-release
cached: IPA_OUTPUT ?= packages/$(BUNDLE_ID)
cached: PACKAGE_FLAGS := -disableAutomaticPackageResolution -skipPackageUpdates

$(SCHEMES) cached:
	xcodebuild \
	    -project Asign.xcodeproj \
	    -scheme "$(SCHEMES)" \
	    -configuration Release \
	    -arch arm64 \
	    -sdk $(PLATFORM) \
	    -derivedDataPath "$(TMP)" \
	    -skipPackagePluginValidation \
	    $(PACKAGE_FLAGS) \
	    "ASIGN_BASE_BUNDLE_ID=$(BUNDLE_ID)" \
	    CODE_SIGNING_ALLOWED=NO \
	    ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	python3 .github/scripts/package_ipa.py --app "$(APP)/$(OUTPUT_NAME).app" --output "$(or $(IPA_OUTPUT),packages)"
