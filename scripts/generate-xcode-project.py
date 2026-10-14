#!/usr/bin/env python3
"""Regenerate the checked-in app project; Python is not needed to open/build it."""
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "ControlLab.xcodeproj"
objects = {}


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def obj(object_name, isa, **fields):
    key = ident(object_name)
    assert key not in objects, object_name
    objects[key] = dict(isa=isa, **fields)
    return key


def file(path, kind, tree="SOURCE_ROOT"):
    return obj("file:" + path, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree=tree)


def build(name, ref, **fields):
    return obj("build:" + name, "PBXBuildFile", fileRef=ref, **fields)


def phase(object_name, isa, files, **fields):
    return obj(object_name, isa, buildActionMask="2147483647", files=files, runOnlyForDeploymentPostprocessing="0", **fields)


def configs(name, base, native=None):
    items = []
    for config in ("Debug", "Release", "NativeGamepad"):
        settings = dict(base)
        settings.update(SWIFT_OPTIMIZATION_LEVEL="-O" if config == "Release" else "-Onone",
                        DEBUG_INFORMATION_FORMAT="dwarf-with-dsym" if config == "Release" else "dwarf")
        if config != "Release":
            settings.update(ENABLE_TESTABILITY="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG")
        if config == "NativeGamepad" and native:
            settings.update(native)
        items.append(obj(name + ":" + config, "XCBuildConfiguration", name=config, buildSettings=settings))
    return obj(name + ":configs", "XCConfigurationList", buildConfigurations=items,
               defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


sources = sorted((ROOT / "Sources/Vader5GUI").glob("*.swift"))
refs = {p.name: file(str(p.relative_to(ROOT)), "sourcecode.swift") for p in sources}
helper_names = {"DockLightingPreview.swift", "RGBPreviewApp.swift"}
app_sources = [build("app:" + name, ref) for name, ref in refs.items() if name not in helper_names]
helper_sources = [build("helper:" + name, ref) for name, ref in refs.items() if name in helper_names]
resource_paths = [
    ("Resources/ControlLab.icns", "image.icns"),
    ("Resources/ControlLab.png", "image.png"),
    ("Sources/Vader5GUI/Resources/Vader5Pro-Official.png", "image.png"),
    ("Sources/Vader5GUI/Resources/FlydigiDock2Pro-Official.jpg", "image.jpeg"),
    ("Sources/Vader5GUI/Resources/FlydigiDock2Pro-Front.png", "image.png"),
    ("Sources/Vader5GUI/Resources/FlydigiDockDefaults", "folder"),
    ("ThirdPartyNotices", "folder"),
]
resources = [file(path, kind) for path, kind in resource_paths]
framework = file("Vendor/SDL3.xcframework/macos-arm64_x86_64/SDL3.framework", "wrapper.framework")
app_product = file("ControlLab.app", "wrapper.application", "BUILT_PRODUCTS_DIR")
helper_product = file("ControlLabRGBPreview", "compiled.mach-o.executable", "BUILT_PRODUCTS_DIR")
info = file("Xcode/Info.plist", "text.plist.xml")
entitlements = file("ControlLab.entitlements", "text.plist.entitlements")
package = obj("package", "XCLocalSwiftPackageReference", relativePath=".")
app_core = obj("app-core", "XCSwiftPackageProductDependency", package=package, productName="Vader5Core")
helper_core = obj("helper-core", "XCSwiftPackageProductDependency", package=package, productName="Vader5Core")
app_link = obj("app-core-link", "PBXBuildFile", productRef=app_core)
helper_link = obj("helper-core-link", "PBXBuildFile", productRef=helper_core)

common = dict(SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="13.0", SWIFT_VERSION="6.0",
              CLANG_ENABLE_MODULES="YES", CODE_SIGN_STYLE="Automatic", DEVELOPMENT_TEAM="",
              ENABLE_HARDENED_RUNTIME="YES", ENABLE_APP_SANDBOX="NO")
app_settings = dict(common, PRODUCT_NAME="ControlLab", PRODUCT_BUNDLE_IDENTIFIER="io.github.dracinn.controllab",
                    INFOPLIST_FILE="Xcode/Info.plist", GENERATE_INFOPLIST_FILE="NO",
                    LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks"],
                    CODE_SIGN_ENTITLEMENTS="", ENABLE_USER_SCRIPT_SANDBOXING="NO")
helper_settings = dict(common, PRODUCT_NAME="ControlLabRGBPreview", SKIP_INSTALL="YES",
                       LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks"])
helper_target = obj("helper-target", "PBXNativeTarget", name="ControlLabRGBPreview", productName="ControlLabRGBPreview",
    productReference=helper_product, productType="com.apple.product-type.tool", buildRules=[], dependencies=[],
    packageProductDependencies=[helper_core], buildConfigurationList=configs("helper", helper_settings), buildPhases=[
        phase("helper-sources", "PBXSourcesBuildPhase", helper_sources),
        phase("helper-frameworks", "PBXFrameworksBuildPhase", [helper_link]),
    ])
proxy = obj("helper-proxy", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType="1",
            remoteGlobalIDString=helper_target, remoteInfo="ControlLabRGBPreview")
dependency = obj("helper-dependency", "PBXTargetDependency", target=helper_target, targetProxy=proxy)
app_target = obj("app-target", "PBXNativeTarget", name="ControlLab", productName="ControlLab",
    productReference=app_product, productType="com.apple.product-type.application", buildRules=[], dependencies=[dependency],
    packageProductDependencies=[app_core], buildConfigurationList=configs("app", app_settings,
        dict(CODE_SIGN_ENTITLEMENTS="ControlLab.entitlements")), buildPhases=[
        phase("app-sources", "PBXSourcesBuildPhase", app_sources),
        phase("app-frameworks", "PBXFrameworksBuildPhase", [app_link]),
        phase("app-resources", "PBXResourcesBuildPhase", [build("resource:" + ref, ref) for ref in resources]),
        # Xcode embeds the transitive SwiftPM binary target (SDL3) itself.
        # An additional Copy Files entry would create two producers for it.
        phase("embed-helper", "PBXCopyFilesBuildPhase", [build("embed-helper", helper_product,
            settings=dict(ATTRIBUTES=["CodeSignOnCopy"]))], name="Embed preview helper", dstPath="", dstSubfolderSpec="6"),
        phase("stamp", "PBXShellScriptBuildPhase", [], name="Record source revision", shellPath="/bin/bash",
              shellScript='"${SRCROOT}/scripts/xcode-stamp.sh"\n', alwaysOutOfDate="1",
              inputPaths=["$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"], outputPaths=[]),
    ])
products = obj("products", "PBXGroup", name="Products", children=[app_product, helper_product], sourceTree="<group>")
group = obj("main-group", "PBXGroup", children=list(refs.values()) + resources + [info, entitlements, framework, products], sourceTree="<group>")
project = obj("project", "PBXProject", attributes=dict(BuildIndependentTargetsInParallel="YES", LastUpgradeCheck="1600"),
    buildConfigurationList=configs("project", {}), compatibilityVersion="Xcode 14.0", developmentRegion="en",
    hasScannedForEncodings="0", knownRegions=["en", "Base"], mainGroup=group, productRefGroup=products,
    projectDirPath="", projectRoot="", targets=[app_target, helper_target], packageReferences=[package])


def serialize(value, indent=0):
    # Quote every scalar, including object IDs: valid OpenStep property-list syntax.
    pad = "\t" * indent
    if isinstance(value, dict):
        return "{\n" + "".join(pad + "\t" + json.dumps(k) + " = " + serialize(v, indent + 1) + ";\n" for k, v in value.items()) + pad + "}"
    if isinstance(value, list):
        return "(\n" + "".join(pad + "\t" + serialize(v, indent + 1) + ",\n" for v in value) + pad + ")"
    return json.dumps(value)


PROJECT.mkdir(exist_ok=True)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(dict(
    archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject=project)) + "\n")
(ROOT / "Xcode").mkdir(exist_ok=True)
with (ROOT / "Resources/Info.plist").open("rb") as stream:
    plist = plistlib.load(stream)
plist.update(CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleExecutable="$(EXECUTABLE_NAME)")
(ROOT / "Xcode/Info.plist").write_bytes(plistlib.dumps(plist))
schemes = PROJECT / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
for name, config in [("ControlLab", "Debug"), ("ControlLab Native Gamepad", "NativeGamepad")]:
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="ControlLab.app" BlueprintName="ControlLab" ReferencedContainer="container:ControlLab.xcodeproj"/>'
    (schemes / (name + ".xcscheme")).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables/></TestAction>
 <LaunchAction buildConfiguration="{config}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="{config}" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="{config}"/>
 <ArchiveAction buildConfiguration="{'NativeGamepad' if config == 'NativeGamepad' else 'Release'}" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated ControlLab.xcodeproj (normal and native-gamepad schemes).")
