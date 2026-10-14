#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
case "$configuration" in debug|release) ;; *) print -u2 'CONFIGURATION must be debug or release.'; exit 1 ;; esac
app_dir="${repo_dir}/build/ControlLab.app"
sdl_framework="${repo_dir}/Vendor/SDL3.xcframework/macos-arm64_x86_64/SDL3.framework"
bundle_identifier="${APP_BUNDLE_IDENTIFIER:-io.github.dracinn.controllab}"

cd "${repo_dir}"
if [[ "$(uname -s)" != "Darwin" ]]; then
    print -u2 "Packaging requires macOS and Xcode command-line tools."
    exit 1
fi
if [[ "${ENABLE_VIRTUAL_HID:-0}" == "1" ]]; then
    if [[ -z "${SIGNING_IDENTITY:-}" || -z "${PROVISIONING_PROFILE:-}" || ! -f "${PROVISIONING_PROFILE}" ]]; then
        print -u2 "Virtual HID requires SIGNING_IDENTITY and an approved PROVISIONING_PROFILE file."
        exit 1
    fi
    mkdir -p "${repo_dir}/.build/signing"
    signing_profile="${repo_dir}/.build/signing/profile.plist"
    signing_entitlements="${repo_dir}/.build/signing/ControlLab.entitlements"
    security cms -D -i "${PROVISIONING_PROFILE}" > "${signing_profile}"
    swift "${repo_dir}/scripts/prepare-native-signing.swift" \
        "${signing_profile}" "${bundle_identifier}" "${signing_entitlements}"
fi
swift_build_args=(--build-system native --scratch-path .build/native -c "${configuration}" -Xswiftc -enable-testing)
if [[ "${SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then
    swift_build_args+=(--disable-sandbox)
fi
if [[ "${CONTROLLAB_SKIP_BUILD:-0}" != "1" ]]; then
    swift build "${swift_build_args[@]}"
fi
bin_dir="$(swift build "${swift_build_args[@]}" --show-bin-path)"
binary="${bin_dir}/ControlLab"
preview_binary="${bin_dir}/ControlLabRGBPreview"
[[ -x "${binary}" && -x "${preview_binary}" ]] || { print -u2 "App binaries are missing. Run ./scripts/build-mac.sh."; exit 1; }
rm -rf "${app_dir}"
mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources/ThirdPartyNotices" \
    "${app_dir}/Contents/Frameworks"
cp "${binary}" "${app_dir}/Contents/MacOS/ControlLab"
cp "${preview_binary}" "${app_dir}/Contents/MacOS/ControlLabRGBPreview"
cp "${repo_dir}/Resources/Info.plist" "${app_dir}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${bundle_identifier}" "${app_dir}/Contents/Info.plist"
cp "${repo_dir}/Resources/ControlLab.icns" "${app_dir}/Contents/Resources/ControlLab.icns"
cp "${repo_dir}/Resources/ControlLab.png" "${app_dir}/Contents/Resources/ControlLab.png"
cp "${repo_dir}/scripts/update.sh" "${repo_dir}/build/update.sh"
chmod +x "${repo_dir}/build/update.sh"
source_revision="$(git -C "${repo_dir}" rev-parse --short HEAD 2>/dev/null || print development)"
if [[ -n "$(git -C "${repo_dir}" status --porcelain 2>/dev/null)" ]]; then
    source_revision="${source_revision}-modified"
fi
/usr/libexec/PlistBuddy -c "Add :ControlLabSourceRevision string ${source_revision}" "${app_dir}/Contents/Info.plist"

cp "${repo_dir}/Sources/Vader5GUI/Resources/Vader5Pro-Official.png" \
    "${app_dir}/Contents/Resources/Vader5Pro-Official.png"
cp "${repo_dir}/Sources/Vader5GUI/Resources/FlydigiDock2Pro-Official.jpg" \
    "${app_dir}/Contents/Resources/FlydigiDock2Pro-Official.jpg"
cp "${repo_dir}/Sources/Vader5GUI/Resources/FlydigiDock2Pro-Front.png" \
    "${app_dir}/Contents/Resources/FlydigiDock2Pro-Front.png"
cp -R "${repo_dir}/Sources/Vader5GUI/Resources/FlydigiDockDefaults" \
    "${app_dir}/Contents/Resources/FlydigiDockDefaults"
cp -R "${sdl_framework}" "${app_dir}/Contents/Frameworks/SDL3.framework"
cp "${repo_dir}/ThirdPartyNotices/SDL3-LICENSE.txt" \
    "${app_dir}/Contents/Resources/ThirdPartyNotices/SDL3-LICENSE.txt"
cp "${repo_dir}/ThirdPartyNotices/FLYDIGI-ASSET-NOTICE.md" \
    "${app_dir}/Contents/Resources/ThirdPartyNotices/FLYDIGI-ASSET-NOTICE.md"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${app_dir}/Contents/MacOS/ControlLab"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${app_dir}/Contents/MacOS/ControlLabRGBPreview"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" \
        "${app_dir}/Contents/Frameworks/SDL3.framework"
    codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" \
        "${app_dir}/Contents/MacOS/ControlLabRGBPreview"
    signing_args=(--force --options runtime --timestamp --sign "${SIGNING_IDENTITY}")
    if [[ "${ENABLE_VIRTUAL_HID:-0}" == "1" ]]; then
        cp "${PROVISIONING_PROFILE}" "${app_dir}/Contents/embedded.provisionprofile"
        signing_args+=(--entitlements "${signing_entitlements}")
    fi
    codesign "${signing_args[@]}" "${app_dir}"
    if [[ "${ENABLE_VIRTUAL_HID:-0}" == "1" ]]; then
        codesign --display --extract-certificates "${repo_dir}/.build/signing/cert" "${app_dir}"
        swift "${repo_dir}/scripts/prepare-native-signing.swift" \
            "${signing_profile}" "${bundle_identifier}" "${signing_entitlements}" "${repo_dir}/.build/signing/cert0"
    fi
else
    codesign --force --sign - "${app_dir}/Contents/Frameworks/SDL3.framework"
    codesign --force --sign - "${app_dir}/Contents/MacOS/ControlLabRGBPreview"
    codesign --force --sign - "${app_dir}"
fi

codesign --verify --deep --strict "${app_dir}"

print "Built ${app_dir}"
