#!/usr/bin/env python3
"""Add CeciliasNotesMacTests unit-test target and wire it into the Mac scheme."""
from pathlib import Path

PBX = Path(__file__).resolve().parents[1] / "CeciliasNotes.xcodeproj" / "project.pbxproj"
SCHEME = Path(__file__).resolve().parents[1] / "CeciliasNotes.xcodeproj" / "xcshareddata" / "xcschemes" / "CeciliasNotesMac.xcscheme"

# IDs use a dedicated prefix — do not reuse C0A1A0A12FAD1000000000xx (taken by Mac sync groups).
G = "C0A1MAC100000000000001"  # synced root group
P = "C0A1MAC100000000000002"  # product .xctest
T = "C0A1MAC100000000000003"  # native target
S = "C0A1MAC100000000000004"  # sources phase
F = "C0A1MAC100000000000005"  # frameworks phase
R = "C0A1MAC100000000000006"  # resources phase
C = "C0A1MAC100000000000007"  # config list
D = "C0A1MAC100000000000008"  # debug config
E = "C0A1MAC100000000000009"  # release config
X = "C0A1MAC10000000000000A"  # container proxy
Y = "C0A1MAC10000000000000B"  # target dependency

text = PBX.read_text()
if T in text:
    print("Mac test target already present")
    raise SystemExit(0)

text = text.replace(
    "\t\tC0A1A0A12FAD100000000001 /* CeciliasNotesMac.app */ = {isa = PBXFileReference;",
    f"\t\t{P} /* CeciliasNotesMacTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = CeciliasNotesMacTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};\n\t\tC0A1A0A12FAD100000000001 /* CeciliasNotesMac.app */ = {{isa = PBXFileReference;",
)

text = text.replace(
    "\t\tC0A1A0A12FAD100000000003 /* CeciliasNotesMac */ = {",
    f"\t\t{G} /* CeciliasNotesMacTests */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = CeciliasNotesMacTests;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n\t\tC0A1A0A12FAD100000000003 /* CeciliasNotesMac */ = {{",
)

text = text.replace(
    "\t\t\tC0A1A0A12FAD100000000003 /* CeciliasNotesMac */,\n\t\t\tABB82E302FAD01B400EAEC50 /* CeciliasNotesTests */,",
    f"\t\t\tC0A1A0A12FAD100000000003 /* CeciliasNotesMac */,\n\t\t\t{G} /* CeciliasNotesMacTests */,\n\t\t\tABB82E302FAD01B400EAEC50 /* CeciliasNotesTests */,",
)

text = text.replace(
    "\t\t\tC0A1A0A12FAD100000000001 /* CeciliasNotesMac.app */,\n\t\t\tABB82E2D2FAD01B400EAEC50 /* CeciliasNotesTests.xctest */,",
    f"\t\t\tC0A1A0A12FAD100000000001 /* CeciliasNotesMac.app */,\n\t\t\t{P} /* CeciliasNotesMacTests.xctest */,\n\t\t\tABB82E2D2FAD01B400EAEC50 /* CeciliasNotesTests.xctest */,",
)

text = text.replace(
    "/* End PBXContainerItemProxy section */",
    f"\t\t{X} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = ABB82E182FAD01B300EAEC50 /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = C0A1A0A12FAD100000000010;\n\t\t\tremoteInfo = CeciliasNotesMac;\n\t\t}};\n/* End PBXContainerItemProxy section */",
)

text = text.replace(
    "/* End PBXTargetDependency section */",
    f"\t\t{Y} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = C0A1A0A12FAD100000000010 /* CeciliasNotesMac */;\n\t\t\ttargetProxy = {X} /* PBXContainerItemProxy */;\n\t\t}};\n/* End PBXTargetDependency section */",
)

text = text.replace(
    "/* End PBXFrameworksBuildPhase section */",
    f"\t\t{F} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n/* End PBXFrameworksBuildPhase section */",
)

text = text.replace(
    "/* End PBXResourcesBuildPhase section */",
    f"\t\t{R} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n/* End PBXResourcesBuildPhase section */",
)

text = text.replace(
    "/* End PBXSourcesBuildPhase section */",
    f"\t\t{S} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n/* End PBXSourcesBuildPhase section */",
)

text = text.replace(
    "/* End PBXNativeTarget section */",
    f"""\t\t{T} /* CeciliasNotesMacTests */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {C} /* Build configuration list for PBXNativeTarget "CeciliasNotesMacTests" */;
\t\t\tbuildPhases = (
\t\t\t\t{S} /* Sources */,
\t\t\t\t{F} /* Frameworks */,
\t\t\t\t{R} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t{Y} /* PBXTargetDependency */,
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{G} /* CeciliasNotesMacTests */,
\t\t\t);
\t\t\tname = CeciliasNotesMacTests;
\t\t\tproductName = CeciliasNotesMacTests;
\t\t\tproductReference = {P} /* CeciliasNotesMacTests.xctest */;
\t\t\tproductType = "com.apple.product-type.bundle.unit-test";
\t\t}};
/* End PBXNativeTarget section */""",
)

text = text.replace(
    "\t\t\tC0A1A0A12FAD100000000010 /* CeciliasNotesMac */,\n\t\t\tABB82E2C2FAD01B400EAEC50 /* CeciliasNotesTests */,",
    f"\t\t\tC0A1A0A12FAD100000000010 /* CeciliasNotesMac */,\n\t\t\t{T} /* CeciliasNotesMacTests */,\n\t\t\tABB82E2C2FAD01B400EAEC50 /* CeciliasNotesTests */,",
)

text = text.replace(
    "/* End XCBuildConfiguration section */",
    f"""\t\t{D} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = W9559HJWN9;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 15.0;
\t\t\t\tMARKETING_VERSION = 3.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = app.ceciliasnotes.mac.tests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSTRING_CATALOG_GENERATE_SYMBOLS = NO;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/CeciliasNotesMac.app/$(CONTENTS_FOLDER_PATH)/MacOS/CeciliasNotesMac";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{E} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = W9559HJWN9;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 15.0;
\t\t\t\tMARKETING_VERSION = 3.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = app.ceciliasnotes.mac.tests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = macosx;
\t\t\t\tSTRING_CATALOG_GENERATE_SYMBOLS = NO;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/CeciliasNotesMac.app/$(CONTENTS_FOLDER_PATH)/MacOS/CeciliasNotesMac";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */""",
)

text = text.replace(
    "/* End XCConfigurationList section */",
    f"""\t\t{C} /* Build configuration list for PBXNativeTarget "CeciliasNotesMacTests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{D} /* Debug */,
\t\t\t\t{E} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */""",
)

PBX.write_text(text)

scheme = SCHEME.read_text()
if "CeciliasNotesMacTests" not in scheme:
    scheme = scheme.replace(
        "      shouldAutocreateTestPlan = \"YES\">\n   </TestAction>",
        f"""      shouldAutocreateTestPlan = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{T}"
               BuildableName = "CeciliasNotesMacTests.xctest"
               BlueprintName = "CeciliasNotesMacTests"
               ReferencedContainer = "container:CeciliasNotes.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>""",
    )
    scheme = scheme.replace(
        "</BuildActionEntries>\n   </BuildAction>",
        f"""         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "NO"
            buildForProfiling = "NO"
            buildForArchiving = "NO"
            buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{T}"
               BuildableName = "CeciliasNotesMacTests.xctest"
               BlueprintName = "CeciliasNotesMacTests"
               ReferencedContainer = "container:CeciliasNotes.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>""",
    )
    SCHEME.write_text(scheme)

print("Added CeciliasNotesMacTests target")
