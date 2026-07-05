#!/usr/bin/env python3
"""Add CeciliasNotes shared sources to CeciliasNotesMac target via membership exceptions."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "CeciliasNotes"
PBX = Path(__file__).resolve().parents[1] / "CeciliasNotes.xcodeproj" / "project.pbxproj"

IOS_ONLY_CORE = {
    "Core/Capabilities/DeviceCapabilities.swift",
    "Core/Extensions/AccessibilityExtensions.swift",
    "Core/Services/HapticManager.swift",
    "Core/Services/KeyboardObserver.swift",
    "Core/Utilities/HostingHierarchyDiagnostics.swift",
    "Core/Services/InputCapabilityDetector.swift",
    "Core/Services/MultipeerSyncService.swift",
    "Core/Services/MultipeerPairingStore.swift",
    "Core/Services/ShareInboxWatcher.swift",
    "Core/Services/ImagePickerBridge.swift",
    "Core/Services/ModalPresenter.swift",
    "Core/Services/ModifierKeyObserver.swift",
    "Core/Services/ImageImportNotifications.swift",
}

MAC_INCLUDE_EXTRA = {
    "DesignSystem/NotebookCoverTone.swift",
    "DesignSystem/CeciliasNotesColors.swift",
    "Features/Library/LibraryContext.swift",
    "Features/Library/NotebookNameGenerator.swift",
}

MAC_INCLUDE_CORE = {
    p.relative_to(ROOT).as_posix()
    for p in (ROOT / "Core").rglob("*.swift")
    if p.relative_to(ROOT).as_posix() not in IOS_ONLY_CORE
}

MAC_INCLUDE = MAC_INCLUDE_CORE | MAC_INCLUDE_EXTRA

all_swift = {
    p.relative_to(ROOT).as_posix()
    for p in ROOT.rglob("*.swift")
}

exclusions = sorted(all_swift - MAC_INCLUDE)
print(f"Total swift: {len(all_swift)}, include: {len(MAC_INCLUDE)}, exclude: {len(exclusions)}")

EXCEPTION_ID = "C0A1A0A12FAD100000000020"
exception_block = f"""\t\t{EXCEPTION_ID} /* Exceptions for "CeciliasNotes" folder in "CeciliasNotesMac" target */ = {{
\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;
\t\t\tmembershipExceptions = (
"""
for path in exclusions:
    exception_block += f"\t\t\t\t{path},\n"
exception_block += """\t\t\t);
\t\t\ttarget = C0A1A0A12FAD100000000010 /* CeciliasNotesMac */;
\t\t};
"""

text = PBX.read_text()

marker = "/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */"
if EXCEPTION_ID in text:
    print("Already patched")
    raise SystemExit(0)

text = text.replace(marker, exception_block + marker)

text = text.replace(
    "\t\t\texceptions = (\n\t\t\t\tABB82F2C2FAD037C00EAEC50 /* Exceptions for \"CeciliasNotes\" folder in \"CeciliasNotes\" target */,\n\t\t\t);",
    "\t\t\texceptions = (\n\t\t\t\tABB82F2C2FAD037C00EAEC50 /* Exceptions for \"CeciliasNotes\" folder in \"CeciliasNotes\" target */,\n\t\t\t\tC0A1A0A12FAD100000000020 /* Exceptions for \"CeciliasNotes\" folder in \"CeciliasNotesMac\" target */,\n\t\t\t);",
)

text = text.replace(
    "\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\tC0A1A0A12FAD100000000003 /* CeciliasNotesMac */,\n\t\t\t);",
    "\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\tC0A1A0A12FAD100000000003 /* CeciliasNotesMac */,\n\t\t\t\tABB82E222FAD01B300EAEC50 /* CeciliasNotes */,\n\t\t\t);",
)

PBX.write_text(text)
print("Patched project.pbxproj")
