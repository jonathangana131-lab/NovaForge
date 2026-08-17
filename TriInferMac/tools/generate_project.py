#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import math
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "App"
PROJECT = ROOT / "TriInferCode.xcodeproj"
SCHEME_DIR = PROJECT / "xcshareddata" / "xcschemes"
ASSETS = APP / "Assets.xcassets"
SOURCES = sorted(APP.glob("*.swift"), key=lambda p: p.name.lower())

if not SOURCES:
    raise SystemExit("No Swift sources found in App/")


def uid(key: str) -> str:
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()


def q(value: str) -> str:
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def png_chunk(kind: bytes, data: bytes) -> bytes:
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def write_rgb_png(path: Path, width: int, height: int, rows: list[bytes]) -> None:
    raw = b"".join(b"\x00" + row for row in rows)
    payload = b"\x89PNG\r\n\x1a\n"
    payload += png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    payload += png_chunk(b"IDAT", zlib.compress(raw, 9))
    payload += png_chunk(b"IEND", b"")
    path.write_bytes(payload)


def generate_assets() -> None:
    icon_dir = ASSETS / "AppIcon.appiconset"
    accent_dir = ASSETS / "AccentColor.colorset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    accent_dir.mkdir(parents=True, exist_ok=True)

    (ASSETS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (icon_dir / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "TriInfer-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}
    }, indent=2) + "\n")
    (accent_dir / "Contents.json").write_text(json.dumps({
        "colors": [{
            "idiom": "universal",
            "color": {"color-space": "srgb", "components": {"alpha": "1.000", "red": "0.286", "green": "0.463", "blue": "1.000"}}
        }, {
            "idiom": "universal",
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "color": {"color-space": "srgb", "components": {"alpha": "1.000", "red": "0.408", "green": "0.635", "blue": "1.000"}}
        }],
        "info": {"author": "xcode", "version": 1}
    }, indent=2) + "\n")

    size = 1024
    rows: list[bytes] = []
    for y in range(size):
        row = bytearray()
        ny = y / (size - 1)
        for x in range(size):
            nx = x / (size - 1)
            # Deep indigo background with a restrained central electric glow.
            glow = max(0.0, 1.0 - math.hypot(nx - 0.55, ny - 0.43) / 0.72)
            edge = max(0.0, 1.0 - math.hypot(nx - 0.18, ny - 0.82) / 0.60)
            r = 14 + int(30 * ny + 20 * glow + 12 * edge)
            g = 17 + int(15 * ny + 32 * glow + 8 * edge)
            b = 36 + int(55 * ny + 82 * glow + 35 * edge)

            # Geometric T: bright glassy top beam + tapered neural/inference stem.
            top = 0.235 <= ny <= 0.355 and 0.205 <= nx <= 0.795
            stem_half = 0.093 - max(0.0, ny - 0.35) * 0.038
            stem = 0.33 <= ny <= 0.755 and abs(nx - 0.5) <= stem_half
            if top or stem:
                local = 1.0 - min(1.0, math.hypot(nx - 0.48, ny - 0.40) / 0.55)
                r = min(255, 93 + int(45 * local))
                g = min(255, 205 + int(35 * local))
                b = 255

            # Three compact nodes imply CPU / GPU / ANE converging into one runtime.
            for cx, cy, radius, tint in [
                (0.31, 0.70, 0.052, (89, 222, 255)),
                (0.50, 0.80, 0.052, (132, 146, 255)),
                (0.69, 0.70, 0.052, (196, 114, 255)),
            ]:
                d = math.hypot(nx - cx, ny - cy)
                if d < radius:
                    f = 1.0 - d / radius
                    r = int(r * (1 - f) + tint[0] * f)
                    g = int(g * (1 - f) + tint[1] * f)
                    b = int(b * (1 - f) + tint[2] * f)

            row.extend((max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b))))
        rows.append(bytes(row))
    write_rgb_png(icon_dir / "TriInfer-1024.png", size, size, rows)


generate_assets()

project_id = uid("project")
target_id = uid("target")
product_id = uid("product")
main_group = uid("main-group")
app_group = uid("app-group")
framework_group = uid("framework-group")
products_group = uid("products-group")
sources_phase = uid("sources-phase")
frameworks_phase = uid("frameworks-phase")
resources_phase = uid("resources-phase")
embed_phase = uid("embed-phase")
proj_debug = uid("proj-debug")
proj_release = uid("proj-release")
target_debug = uid("target-debug")
target_release = uid("target-release")
proj_config_list = uid("proj-config-list")
target_config_list = uid("target-config-list")
info_ref = uid("info-ref")
assets_ref = uid("assets-ref")
assets_build = uid("assets-build")
llama_ref = uid("llama-ref")
metal_ref = uid("metal-ref")
accel_ref = uid("accelerate-ref")
webkit_ref = uid("webkit-ref")
llama_build = uid("llama-build")
llama_embed = uid("llama-embed")
metal_build = uid("metal-build")
accel_build = uid("accelerate-build")
webkit_build = uid("webkit-build")
coreml_pkg_ref = uid("coreml-llm-package")
coreml_product = uid("coreml-llm-product")
coreml_build = uid("coreml-llm-build")

source_refs = {p: uid("ref:" + p.name) for p in SOURCES}
source_builds = {p: uid("build:" + p.name) for p in SOURCES}

lines: list[str] = []
a = lines.append
a("// !$*UTF8*$!")
a("{")
a("\tarchiveVersion = 1;")
a("\tclasses = {};")
a("\tobjectVersion = 56;")
a("\tobjects = {")

a("\n/* Begin PBXBuildFile section */")
for p in SOURCES:
    a(f"\t\t{source_builds[p]} /* {p.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {source_refs[p]} /* {p.name} */; }};")
a(f"\t\t{assets_build} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};")
a(f"\t\t{llama_build} /* llama.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {llama_ref} /* llama.xcframework */; }};")
a(f"\t\t{llama_embed} /* llama.xcframework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {llama_ref} /* llama.xcframework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};")
a(f"\t\t{metal_build} /* Metal.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {metal_ref}; }};")
a(f"\t\t{accel_build} /* Accelerate.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {accel_ref}; }};")
a(f"\t\t{webkit_build} /* WebKit.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {webkit_ref}; }};")
a(f"\t\t{coreml_build} /* CoreMLLLM in Frameworks */ = {{isa = PBXBuildFile; productRef = {coreml_product} /* CoreMLLLM */; }};")
a("/* End PBXBuildFile section */")

a("\n/* Begin PBXCopyFilesBuildPhase section */")
a(f"\t\t{embed_phase} /* Embed Frameworks */ = {{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 10; files = ({llama_embed},); name = \"Embed Frameworks\"; runOnlyForDeploymentPostprocessing = 0; }};")
a("/* End PBXCopyFilesBuildPhase section */")

a("\n/* Begin PBXFileReference section */")
for p in SOURCES:
    a(f"\t\t{source_refs[p]} /* {p.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(p.name)}; sourceTree = \"<group>\"; }};")
a(f"\t\t{info_ref} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
a(f"\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};")
a(f"\t\t{product_id} /* TriInfer Code.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \"TriInfer Code.app\"; sourceTree = BUILT_PRODUCTS_DIR; }};")
a(f"\t\t{llama_ref} /* llama.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = llama.xcframework; sourceTree = \"<group>\"; }};")
a(f"\t\t{metal_ref} /* Metal.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = Metal.framework; path = System/Library/Frameworks/Metal.framework; sourceTree = SDKROOT; }};")
a(f"\t\t{accel_ref} /* Accelerate.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = Accelerate.framework; path = System/Library/Frameworks/Accelerate.framework; sourceTree = SDKROOT; }};")
a(f"\t\t{webkit_ref} /* WebKit.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = WebKit.framework; path = System/Library/Frameworks/WebKit.framework; sourceTree = SDKROOT; }};")
a("/* End PBXFileReference section */")

a("\n/* Begin PBXFrameworksBuildPhase section */")
a(f"\t\t{frameworks_phase} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({llama_build}, {coreml_build}, {metal_build}, {accel_build}, {webkit_build},); runOnlyForDeploymentPostprocessing = 0; }};")
a("/* End PBXFrameworksBuildPhase section */")

a("\n/* Begin PBXGroup section */")
app_children = ", ".join(source_refs[p] for p in SOURCES) + f", {info_ref}, {assets_ref}"
a(f"\t\t{app_group} /* App */ = {{isa = PBXGroup; children = ({app_children},); path = App; sourceTree = \"<group>\"; }};")
a(f"\t\t{framework_group} /* Frameworks */ = {{isa = PBXGroup; children = ({llama_ref}, {metal_ref}, {accel_ref}, {webkit_ref},); path = Vendor; sourceTree = \"<group>\"; }};")
a(f"\t\t{products_group} /* Products */ = {{isa = PBXGroup; children = ({product_id},); name = Products; sourceTree = \"<group>\"; }};")
a(f"\t\t{main_group} = {{isa = PBXGroup; children = ({app_group}, {framework_group}, {products_group},); sourceTree = \"<group>\"; }};")
a("/* End PBXGroup section */")

a("\n/* Begin PBXNativeTarget section */")
a(f"\t\t{target_id} /* TriInferCode */ = {{isa = PBXNativeTarget; buildConfigurationList = {target_config_list}; buildPhases = ({sources_phase}, {frameworks_phase}, {resources_phase}, {embed_phase},); buildRules = (); dependencies = (); name = TriInferCode; packageProductDependencies = ({coreml_product},); productName = TriInferCode; productReference = {product_id}; productType = \"com.apple.product-type.application\"; }};")
a("/* End PBXNativeTarget section */")

a("\n/* Begin PBXProject section */")
a(f"\t\t{project_id} /* Project object */ = {{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2600; LastUpgradeCheck = 2600; TargetAttributes = {{{target_id} = {{CreatedOnToolsVersion = 26.1;}};}}; }}; buildConfigurationList = {proj_config_list}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {main_group}; packageReferences = ({coreml_pkg_ref},); productRefGroup = {products_group}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({target_id},); }};")
a("/* End PBXProject section */")

a("\n/* Begin PBXResourcesBuildPhase section */")
a(f"\t\t{resources_phase} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({assets_build},); runOnlyForDeploymentPostprocessing = 0; }};")
a("/* End PBXResourcesBuildPhase section */")

a("\n/* Begin PBXSourcesBuildPhase section */")
source_build_list = ", ".join(source_builds[p] for p in SOURCES)
a(f"\t\t{sources_phase} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({source_build_list},); runOnlyForDeploymentPostprocessing = 0; }};")
a("/* End PBXSourcesBuildPhase section */")

a("\n/* Begin XCBuildConfiguration section */")
proj_common = 'ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 26.0; SWIFT_VERSION = 6.0;'
a(f"\t\t{proj_debug} = {{isa = XCBuildConfiguration; buildSettings = {{{proj_common} DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES; SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";}}; name = Debug; }};")
a(f"\t\t{proj_release} = {{isa = XCBuildConfiguration; buildSettings = {{{proj_common} DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\"; SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = \"-O\";}}; name = Release; }};")
target_common = 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 400; ENABLE_PREVIEWS = YES; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = App/Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 26.0; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks",); MARKETING_VERSION = 4.0; PRODUCT_BUNDLE_IDENTIFIER = ai.triinfer.code; PRODUCT_NAME = "TriInfer Code"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = 1;'
a(f"\t\t{target_debug} = {{isa = XCBuildConfiguration; buildSettings = {{{target_common} GCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\",);}}; name = Debug; }};")
a(f"\t\t{target_release} = {{isa = XCBuildConfiguration; buildSettings = {{{target_common}}}; name = Release; }};")
a("/* End XCBuildConfiguration section */")

a("\n/* Begin XCConfigurationList section */")
a(f"\t\t{proj_config_list} = {{isa = XCConfigurationList; buildConfigurations = ({proj_debug}, {proj_release},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")
a(f"\t\t{target_config_list} = {{isa = XCConfigurationList; buildConfigurations = ({target_debug}, {target_release},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")
a("/* End XCConfigurationList section */")

a("\n/* Begin XCRemoteSwiftPackageReference section */")
a(f"\t\t{coreml_pkg_ref} /* CoreML-LLM */ = {{isa = XCRemoteSwiftPackageReference; repositoryURL = \"https://github.com/john-rocky/CoreML-LLM\"; requirement = {{kind = upToNextMajorVersion; minimumVersion = 1.9.0; }}; }};")
a("/* End XCRemoteSwiftPackageReference section */")

a("\n/* Begin XCSwiftPackageProductDependency section */")
a(f"\t\t{coreml_product} /* CoreMLLLM */ = {{isa = XCSwiftPackageProductDependency; package = {coreml_pkg_ref} /* CoreML-LLM */; productName = CoreMLLLM; }};")
a("/* End XCSwiftPackageProductDependency section */")

a("\t};")
a(f"\trootObject = {project_id};")
a("}")

PROJECT.mkdir(parents=True, exist_ok=True)
(PROJECT / "project.pbxproj").write_text("\n".join(lines) + "\n")
SCHEME_DIR.mkdir(parents=True, exist_ok=True)

scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="TriInfer Code.app" BlueprintName="TriInferCode" ReferencedContainer="container:TriInferCode.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="TriInfer Code.app" BlueprintName="TriInferCode" ReferencedContainer="container:TriInferCode.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="TriInfer Code.app" BlueprintName="TriInferCode" ReferencedContainer="container:TriInferCode.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(SCHEME_DIR / "TriInferCode.xcscheme").write_text(scheme)
print(f"Generated Xcode 26.1 / iOS 26+ {PROJECT} with {len(SOURCES)} active Swift sources, branded assets, llama.cpp Metal + CoreML ANE acceleration")
