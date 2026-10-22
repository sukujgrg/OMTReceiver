#!/usr/bin/env python3
"""Regenerate the checked-in native Xcode application/test project. No packages required."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parent.parent
version = (ROOT / 'VERSION').read_text().strip()
build_number = (ROOT / 'BUILD_NUMBER').read_text().strip()
if not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', version):
    raise SystemExit('VERSION must be X.Y or X.Y.Z')
if not re.fullmatch(r'[1-9][0-9]*', build_number):
    raise SystemExit('BUILD_NUMBER must be a positive integer')

def uid(key):
    return hashlib.sha1(key.encode()).hexdigest()[:24].upper()

def q(value):
    return json.dumps(str(value))

objects = []

def obj(key, body):
    ident = uid(key)
    objects.append(f'\t\t{ident} = {{ {body} }};')
    return ident

def ref(path, kind):
    return obj('file:' + path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = "<group>";')

def array(items):
    return '(' + ', '.join(items) + (',' if items else '') + ')'

app_sources = sorted([p for p in (ROOT/'OMTReceiver').rglob('*') if p.suffix in ('.swift', '.m', '.mm', '.c', '.cpp')])
vendor_sources = [ROOT/'Vendor/libvmx/src/vmxcodec.cpp', ROOT/'Vendor/libvmx/src/vmxcodec_arm.cpp']
test_sources = sorted(p for p in (ROOT/'OMTReceiverTests').iterdir() if p.suffix in ('.swift', '.mm'))
ui_sources = sorted((ROOT/'OMTReceiverUITests').glob('*.swift'))
file_refs = {}
for path in app_sources + vendor_sources + test_sources + ui_sources:
    rel = path.relative_to(ROOT).as_posix()
    kind = {'.swift':'sourcecode.swift', '.m':'sourcecode.c.objc', '.mm':'sourcecode.cpp.objcpp', '.cpp':'sourcecode.cpp.cpp', '.c':'sourcecode.c.c'}[path.suffix]
    file_refs[rel] = ref(rel, kind)

app_headers = sorted((ROOT/'OMTReceiver').rglob('*.h'))
for path in app_headers:
    rel = path.relative_to(ROOT).as_posix()
    file_refs[rel] = ref(rel, 'sourcecode.c.h')

assets_ref = ref('OMTReceiver/Assets.xcassets', 'folder.assetcatalog')
signing_ref = ref('Config/Signing.xcconfig', 'text.xcconfig')
app_resource_paths = ['OMTReceiver/PrivacyInfo.xcprivacy'] + [p.relative_to(ROOT).as_posix() for p in sorted((ROOT/'OMTReceiver/Resources').glob('*.txt'))]
resource_refs = [ref(p, 'text.xml' if p.endswith('.xcprivacy') else 'text') for p in app_resource_paths]
info_ref = ref('OMTReceiver/Info.plist', 'text.plist.xml')
readme_ref = ref('README.md', 'net.daringfireball.markdown')
vendor_license = ref('Vendor/libvmx/LICENSE.txt', 'text')
app_product = obj('app-product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OMTReceiver.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_product = obj('test-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = OMTReceiverTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
ui_product = obj('ui-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = OMTReceiverUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')

def source_phase(key, paths):
    builds = []
    for path in paths:
        rel = path.relative_to(ROOT).as_posix()
        builds.append(obj(key + ':' + rel, f'isa = PBXBuildFile; fileRef = {file_refs[rel]};'))
    return obj(key, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(builds)}; runOnlyForDeploymentPostprocessing = 0;')

app_phase = source_phase('app-sources', app_sources + vendor_sources)
test_phase = source_phase('test-sources', test_sources)
ui_phase = source_phase('ui-sources', ui_sources)
resource_build = obj('assets-build', f'isa = PBXBuildFile; fileRef = {assets_ref};')
resource_builds = [resource_build] + [obj('resource-build:' + path, f'isa = PBXBuildFile; fileRef = {reference};') for path, reference in zip(app_resource_paths, resource_refs)]
resources = obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resource_builds)}; runOnlyForDeploymentPostprocessing = 0;')
frameworks = obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')

source_group = obj('source-group', 'isa = PBXGroup; name = Application; children = ' + array([file_refs[p.relative_to(ROOT).as_posix()] for p in app_sources + app_headers] + [info_ref, assets_ref] + resource_refs) + '; sourceTree = "<group>";')
test_group = obj('test-group', 'isa = PBXGroup; name = Tests; children = ' + array([file_refs[p.relative_to(ROOT).as_posix()] for p in test_sources]) + '; sourceTree = "<group>";')
ui_group = obj('ui-group', 'isa = PBXGroup; name = "UI Tests"; children = ' + array([file_refs[p.relative_to(ROOT).as_posix()] for p in ui_sources]) + '; sourceTree = "<group>";')
vendor_group = obj('vendor-group', 'isa = PBXGroup; name = "VMX Codec (MIT)"; children = ' + array([file_refs[p.relative_to(ROOT).as_posix()] for p in vendor_sources] + [vendor_license]) + '; sourceTree = "<group>";')
products = obj('products', f'isa = PBXGroup; name = Products; children = ({app_product}, {test_product}, {ui_product},); sourceTree = "<group>";')
main_group = obj('main-group', f'isa = PBXGroup; children = ({source_group}, {test_group}, {ui_group}, {vendor_group}, {readme_ref}, {signing_ref}, {products},); sourceTree = "<group>";')

common = {
    'ARCHS': 'arm64', 'SDKROOT': 'appletvos', 'SUPPORTED_PLATFORMS': 'appletvos appletvsimulator',
    'TVOS_DEPLOYMENT_TARGET':'17.0', 'TARGETED_DEVICE_FAMILY':'3',
    'CLANG_CXX_LANGUAGE_STANDARD':'c++17', 'CLANG_CXX_LIBRARY':'libc++',
    'CLANG_ENABLE_MODULES':'YES', 'CLANG_ENABLE_OBJC_ARC':'YES',
    'SWIFT_VERSION':'5.0', 'SWIFT_STRICT_CONCURRENCY':'targeted',
    'ENABLE_USER_SCRIPT_SANDBOXING':'YES', 'DEAD_CODE_STRIPPING':'YES',
    'GCC_WARN_ABOUT_RETURN_TYPE':'YES_ERROR', 'CLANG_WARN_DOCUMENTATION_COMMENTS':'YES',
    'OMT_RUN_INTEROP':'0',
}
app_settings = {
    'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER':'com.suku.OMTReceiver',
    'INFOPLIST_FILE':'OMTReceiver/Info.plist', 'GENERATE_INFOPLIST_FILE':'NO',
    'MARKETING_VERSION':version, 'CURRENT_PROJECT_VERSION':build_number,
    'CODE_SIGN_STYLE':'Automatic',
    'SWIFT_OBJC_BRIDGING_HEADER':'OMTReceiver/Codec/OMTReceiver-Bridging-Header.h',
    'HEADER_SEARCH_PATHS':'$(inherited) $(SRCROOT)/Vendor/libvmx/src $(SRCROOT)/OMTReceiver/Codec',
    'OTHER_CPLUSPLUSFLAGS':'$(inherited) -fdeclspec',
    'GCC_OPTIMIZATION_LEVEL':'3', 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks',
    'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME':'',
    'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon',
    'SWIFT_EMIT_LOC_STRINGS':'YES', 'ENABLE_PREVIEWS':'YES',
}
test_settings = {
    'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER':'com.suku.OMTReceiverTests',
    'GENERATE_INFOPLIST_FILE':'YES', 'CODE_SIGN_STYLE':'Automatic',
    'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/OMTReceiver.app/OMTReceiver', 'BUNDLE_LOADER':'$(TEST_HOST)',
    'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks',
}
ui_settings = {
    'PRODUCT_NAME':'$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER':'com.suku.OMTReceiverUITests',
    'GENERATE_INFOPLIST_FILE':'YES', 'CODE_SIGN_STYLE':'Automatic',
    'TEST_TARGET_NAME':'OMTReceiver',
}

def config_list(key, settings):
    ids=[]
    for mode in ('Debug', 'Release'):
        values=dict(settings)
        if key == 'project':
            values['DEBUG_INFORMATION_FORMAT'] = 'dwarf' if mode == 'Debug' else 'dwarf-with-dsym'
            values['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if mode == 'Debug' else '-O'
            if mode == 'Debug':
                values['ENABLE_TESTABILITY'] = 'YES'
                values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
                values['GCC_PREPROCESSOR_DEFINITIONS'] = 'DEBUG=1 $(inherited)'
        rendered=' '.join(f'{k} = {q(v)};' for k,v in sorted(values.items()))
        base = f'baseConfigurationReference = {signing_ref}; ' if key == 'project' else ''
        ids.append(obj(f'{key}-{mode}', f'isa = XCBuildConfiguration; {base}buildSettings = {{ {rendered} }}; name = {mode};'))
    return obj(key + '-config-list', f'isa = XCConfigurationList; buildConfigurations = {array(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

project_configs = config_list('project', common)
app_configs = config_list('app', app_settings)
test_configs = config_list('tests', test_settings)
ui_configs = config_list('ui-tests', ui_settings)
app_target = uid('app-target')
test_target = uid('test-target')
ui_target = uid('ui-target')
proxy = obj('app-proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = OMTReceiver;')
dependency = obj('test-app-dependency', f'isa = PBXTargetDependency; target = {app_target}; targetProxy = {proxy};')
obj('app-target', f'isa = PBXNativeTarget; buildConfigurationList = {app_configs}; buildPhases = ({app_phase}, {frameworks}, {resources},); buildRules = (); dependencies = (); name = OMTReceiver; productName = OMTReceiver; productReference = {app_product}; productType = "com.apple.product-type.application";')
obj('test-target', f'isa = PBXNativeTarget; buildConfigurationList = {test_configs}; buildPhases = ({test_phase},); buildRules = (); dependencies = ({dependency},); name = OMTReceiverTests; productName = OMTReceiverTests; productReference = {test_product}; productType = "com.apple.product-type.bundle.unit-test";')
obj('ui-target', f'isa = PBXNativeTarget; buildConfigurationList = {ui_configs}; buildPhases = ({ui_phase},); buildRules = (); dependencies = ({dependency},); name = OMTReceiverUITests; productName = OMTReceiverUITests; productReference = {ui_product}; productType = "com.apple.product-type.bundle.ui-testing";')
project = obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; TargetAttributes = {{ {app_target} = {{ CreatedOnToolsVersion = 27.1; }}; {test_target} = {{ CreatedOnToolsVersion = 27.1; TestTargetID = {app_target}; }}; {ui_target} = {{ CreatedOnToolsVersion = 27.1; TestTargetID = {app_target}; }}; }}; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({app_target}, {test_target}, {ui_target},);')
pbx = '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {project};\n}}\n'
(ROOT/'OMTReceiver.xcodeproj/project.pbxproj').write_text(pbx)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="OMTReceiver.app" BlueprintName="OMTReceiver" ReferencedContainer="container:OMTReceiver.xcodeproj"/>
    </BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO">
    <MacroExpansion><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="OMTReceiver.app" BlueprintName="OMTReceiver" ReferencedContainer="container:OMTReceiver.xcodeproj"/></MacroExpansion>
    <EnvironmentVariables><EnvironmentVariable key="OMT_UNIT_TESTS" value="1" isEnabled="YES"/><EnvironmentVariable key="OMT_RUN_INTEROP" value="$(OMT_RUN_INTEROP)" isEnabled="YES"/></EnvironmentVariables>
    <Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="OMTReceiverTests.xctest" BlueprintName="OMTReceiverTests" ReferencedContainer="container:OMTReceiver.xcodeproj"/></TestableReference><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_target}" BuildableName="OMTReceiverUITests.xctest" BlueprintName="OMTReceiverUITests" ReferencedContainer="container:OMTReceiver.xcodeproj"/></TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="OMTReceiver.app" BlueprintName="OMTReceiver" ReferencedContainer="container:OMTReceiver.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="OMTReceiver.app" BlueprintName="OMTReceiver" ReferencedContainer="container:OMTReceiver.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(ROOT/'OMTReceiver.xcodeproj/xcshareddata/xcschemes/OMTReceiver.xcscheme').write_text(scheme)
interop_scheme = scheme.replace('key="OMT_RUN_INTEROP" value="$(OMT_RUN_INTEROP)"', 'key="OMT_RUN_INTEROP" value="1"')
(ROOT/'OMTReceiver.xcodeproj/xcshareddata/xcschemes/OMTReceiverInterop.xcscheme').write_text(interop_scheme)
print(f'Generated native tvOS application and test targets ({len(app_sources)} application files, {len(test_sources)} test files).')
