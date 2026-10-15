#!/usr/bin/env python3
"""Generate the Xcode project without an external project generator."""

import hashlib
import json
import plistlib
import re
from pathlib import Path

from build_native import IOS_DEPLOYMENT_TARGET

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def obj(object_key, **fields):
    ident = hashlib.sha256(object_key.encode()).hexdigest()[:24].upper()
    objects[ident] = fields
    return ident


def render(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        return (
            "{\n"
            + "".join(
                indent + "\t" + json.dumps(k) + " = " + render(v, depth + 1) + ";\n"
                for k, v in value.items()
            )
            + indent
            + "}"
        )
    if isinstance(value, list):
        return "(" + ", ".join(render(v, depth) for v in value) + ")"
    return json.dumps(value)


def main():
    objects.clear()
    existing = ROOT / "PipecatVoice.xcodeproj/project.pbxproj"
    signing_team = None
    if existing.exists():
        match = re.search(r'"?DEVELOPMENT_TEAM"?\s*=\s*"?([A-Z0-9]+)"?\s*;', existing.read_text())
        if match:
            signing_team = match.group(1)
    files, compiled, bundled = [], [], []
    for path in sorted((ROOT / "src/ios/PipecatVoice").iterdir()):
        if path.suffix not in {".swift", ".m", ".h", ".xcassets", ".xcprivacy"}:
            continue
        kind = {
            ".swift": "sourcecode.swift",
            ".m": "sourcecode.c.objc",
            ".h": "sourcecode.c.h",
            ".xcassets": "folder.assetcatalog",
            ".xcprivacy": "text.xml",
        }[path.suffix]
        ref = obj(
            path.name,
            isa="PBXFileReference",
            lastKnownFileType=kind,
            path=path.name,
            sourceTree="<group>",
        )
        files.append(ref)
        if path.suffix in {".xcassets", ".xcprivacy"}:
            bundled.append(obj(path.name + "-build", isa="PBXBuildFile", fileRef=ref))
        elif path.suffix != ".h":
            compiled.append(obj(path.name + "-build", isa="PBXBuildFile", fileRef=ref))
    source_group = obj(
        "sources", isa="PBXGroup", children=files, path="src/ios/PipecatVoice", sourceTree="<group>"
    )
    python = obj(
        "python",
        isa="PBXFileReference",
        lastKnownFileType="wrapper.xcframework",
        path="Vendor/Python.xcframework",
        sourceTree="<group>",
    )
    python_link = obj("python-link", isa="PBXBuildFile", fileRef=python)
    python_embed = obj(
        "python-embed",
        isa="PBXBuildFile",
        fileRef=python,
        settings={"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]},
    )
    product = obj(
        "product",
        isa="PBXFileReference",
        explicitFileType="wrapper.application",
        path="PipecatVoice.app",
        sourceTree="BUILT_PRODUCTS_DIR",
    )
    products = obj(
        "products", isa="PBXGroup", children=[product], name="Products", sourceTree="<group>"
    )
    group = obj(
        "root-group",
        isa="PBXGroup",
        children=[source_group, python, products],
        sourceTree="<group>",
    )
    sources = obj(
        "sources-phase",
        isa="PBXSourcesBuildPhase",
        buildActionMask=2147483647,
        files=compiled,
        runOnlyForDeploymentPostprocessing=0,
    )
    frameworks = obj(
        "framework-phase",
        isa="PBXFrameworksBuildPhase",
        buildActionMask=2147483647,
        files=[python_link],
        runOnlyForDeploymentPostprocessing=0,
    )
    resources = obj(
        "resources-phase",
        isa="PBXResourcesBuildPhase",
        buildActionMask=2147483647,
        files=bundled,
        runOnlyForDeploymentPostprocessing=0,
    )
    bundle = obj(
        "bundle-phase",
        isa="PBXShellScriptBuildPhase",
        buildActionMask=2147483647,
        files=[],
        inputPaths=[],
        outputPaths=[
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/PythonRuntime.stamp"
        ],
        name="Bundle Python, Phonon and Audience",
        shellPath="/bin/sh",
        shellScript='set -eu\n"$SRCROOT/.venv/bin/python" "$SRCROOT/scripts/bundle_runtime.py"\n',
        alwaysOutOfDate=1,
        runOnlyForDeploymentPostprocessing=0,
    )
    embed = obj(
        "embed-phase",
        isa="PBXCopyFilesBuildPhase",
        buildActionMask=2147483647,
        dstPath="",
        dstSubfolderSpec=10,
        files=[python_embed],
        name="Embed Frameworks",
        runOnlyForDeploymentPostprocessing=0,
    )
    common = {
        "ARCHS": "arm64",
        "SDKROOT": "iphoneos",
        "IPHONEOS_DEPLOYMENT_TARGET": IOS_DEPLOYMENT_TARGET,
        "SWIFT_VERSION": "5.0",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "SWIFT_STRICT_CONCURRENCY": "targeted",
        # Accelerate's current LAPACK interface (lip-sync root finding uses dgeev).
        "OTHER_SWIFT_FLAGS": ["$(inherited)", "-Xcc", "-DACCELERATE_NEW_LAPACK"],
    }
    target_settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": "ai.pipecat.voice",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO",
        "CODE_SIGN_STYLE": "Automatic",
        "INFOPLIST_FILE": "src/ios/PipecatVoice/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO",
        "SWIFT_OBJC_BRIDGING_HEADER": "src/ios/PipecatVoice/PipecatVoice-Bridging-Header.h",
        "HEADER_SEARCH_PATHS": ["$(inherited)", "$(SRCROOT)/native/phonon-ffi/include"],
        "LIBRARY_SEARCH_PATHS[sdk=iphoneos*]": [
            "$(inherited)",
            "$(SRCROOT)/.build/rust/aarch64-apple-ios/release",
        ],
        "LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]": [
            "$(inherited)",
            "$(SRCROOT)/.build/rust/aarch64-apple-ios-sim/release",
        ],
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "OTHER_LDFLAGS": [
            "$(inherited)",
            "-lphonon_ffi",
            "-framework",
            "NaturalLanguage",
            "-framework",
            "SoundAnalysis",
        ],
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "NO",
        "MARKETING_VERSION": "0.1.0",
        "CURRENT_PROJECT_VERSION": "1",
    }
    if signing_team:
        target_settings["DEVELOPMENT_TEAM"] = signing_team

    def configurations(prefix, base):
        values = []
        for name in ["Debug", "Release"]:
            settings = dict(base)
            if name == "Debug":
                settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = [
                    *settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ["$(inherited)"]),
                    "DEBUG",
                ]
                settings["GCC_PREPROCESSOR_DEFINITIONS"] = ["$(inherited)", "DEBUG=1"]
            settings.update(
                {
                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O",
                    "GCC_OPTIMIZATION_LEVEL": "0" if name == "Debug" else "s",
                    "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym",
                }
            )
            values.append(
                obj(
                    prefix + name,
                    isa="XCBuildConfiguration",
                    name=name,
                    buildSettings=settings,
                )
            )
        return obj(
            prefix + "configs",
            isa="XCConfigurationList",
            buildConfigurations=values,
            defaultConfigurationIsVisible=0,
            defaultConfigurationName="Release",
        )

    target = obj(
        "target",
        isa="PBXNativeTarget",
        name="PipecatVoice",
        productName="PipecatVoice",
        productType="com.apple.product-type.application",
        productReference=product,
        buildConfigurationList=configurations("target", target_settings),
        buildPhases=[sources, frameworks, resources, bundle, embed],
        buildRules=[],
        dependencies=[],
    )
    project = obj(
        "project",
        isa="PBXProject",
        buildConfigurationList=configurations("project", common),
        compatibilityVersion="Xcode 14.0",
        developmentRegion="en",
        hasScannedForEncodings=0,
        knownRegions=["en", "Base"],
        mainGroup=group,
        productRefGroup=products,
        projectDirPath="",
        projectRoot="",
        targets=[target],
        attributes={"LastUpgradeCheck": "2700", "BuildIndependentTargetsInParallel": "YES"},
    )
    folder = ROOT / "PipecatVoice.xcodeproj"
    folder.mkdir(exist_ok=True)
    document = {
        "archiveVersion": 1,
        "classes": {},
        "objectVersion": 56,
        "objects": objects,
        "rootObject": project,
    }
    (folder / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render(document) + "\n")
    schemes = folder / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="PipecatVoice.app" BlueprintName="PipecatVoice" ReferencedContainer="container:PipecatVoice.xcodeproj"/>'
    (schemes / "PipecatVoice.xcscheme").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
""")
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": "Little Voices",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Little Voices",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSRequiresIPhoneOS": True,
        "NSMicrophoneUsageDescription": "Little Voices uses your microphone for voice conversations.",
        "NSSpeechRecognitionUsageDescription": "Little Voices transcribes your voice with Apple’s on-device speech recognition.",
        # The splash art, centred and unscaled: each idiom's image covers its largest screen.
        "UILaunchScreen": {
            "UIColorName": "LaunchBackground",
            "UIImageName": "LaunchSplash",
            "UIImageRespectsSafeAreaInsets": False,
        },
        # Lets the stage animate at 120 Hz on ProMotion iPhones.
        "CADisableMinimumFrameDurationOnPhone": True,
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
        "UISupportedInterfaceOrientations~ipad": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
    }
    (ROOT / "src/ios/PipecatVoice/Info.plist").write_bytes(plistlib.dumps(info))
    print("Generated PipecatVoice.xcodeproj")


if __name__ == "__main__":
    main()
