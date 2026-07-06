#!/usr/bin/env python3
"""Static wiring check for recently implemented flows (batches 11–14)."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CECILIAS = ROOT / "CeciliasNotes"
APP_SRC = CECILIAS / "CeciliasNotes"
YAML_PATH = ROOT / "Documentation" / "USER_FLOWS.yaml"
GRAPH_PATH = ROOT / "Documentation" / "CODE_GRAPH.json"

# Flows we expect fully wired after batches 11–14.
FLOW_IDS = [
    "mac_capture.templates",
    "mac_capture.smart_lists",
    "mac_capture.command_palette",
    "system.services_menu",
    "accessibility.shortcuts",
    "sync.peer_pairing",
    "sync.conflict_resolution",
    "settings.multipeer_pairing",
    "handoff.ipad_to_mac",
    "handoff.mac_to_ipad",
    "widgets.deep_link",
    "system.share_extension",
    "system.spotlight",
]

REQUIRED_SYMBOLS: dict[str, list[tuple[str, str]]] = {
    "handoff.ipad_to_mac": [
        ("CeciliasNotesMac/Editor/MacEditorView.swift", "PageHandoff"),
        ("Features/Editor/EditorView.swift", "editorPageHandoff"),
    ],
    "handoff.mac_to_ipad": [
        ("App/CeciliasNotesApp.swift", "PageHandoff.parse"),
        ("CeciliasNotesMac/App/MacAppDelegate.swift", "PageHandoff"),
    ],
    "sync.conflict_resolution": [
        ("Core/Services/SyncConflictLog.swift", "SyncConflictLog"),
        ("Features/Sync/CloudConflictResolutionSection.swift", "CloudConflictResolutionSection"),
        ("Core/Services/CeciliasNotesImporter.swift", "SyncConflictLog.record"),
    ],
    "system.spotlight": [
        ("CeciliasNotesMac/MacRootView.swift", "refreshAll"),
        ("CeciliasNotesMac/MacRootView.swift", "CSSearchableItemActionType"),
    ],
    "mac_capture.smart_lists": [
        ("Features/Library/MacSmartList.swift", "MacSmartList"),
        ("Features/Library/Sidebar/SubjectSidebarView.swift", "MacSmartListRow"),
    ],
    "mac_capture.templates": [
        ("CeciliasNotesMac/Capture/MacNotebookTemplateService.swift", "MacNotebookTemplate"),
        ("CeciliasNotesMac/MacRootView.swift", "macNewFromTemplate"),
    ],
    "system.share_extension": [
        ("CeciliasNotesShareExtension/ShareViewController.swift", "writeCapturePayload"),
        ("Core/Services/ShareInboxWatcher.swift", "shareInboxCaptureArrived"),
        ("Features/Library/LibraryView.swift", "ingestShareCaptureFile"),
        ("App/CeciliasNotesApp.swift", "ShareInboxWatcher.shared.start"),
    ],
}

NOTIFICATION_WIRING = [
    ("shareInboxCaptureArrived", "ShareInboxWatcher", "LibraryView"),
    ("syncConflictLogChanged", "SyncConflictLog", "CloudConflictResolutionSection"),
    ("macOpenNotebook", "MacQuickCaptureService", "MacRootView"),
    ("macNewFromTemplate", "MacToolbar", "MacRootView"),
]

PLIST_CHECKS = [
    (
        CECILIAS / "CeciliasNotes" / "Resources" / "Info.plist",
        "app.ceciliasnotes.page",
        "iOS NSUserActivityTypes",
    ),
    (
        CECILIAS / "CeciliasNotesMac" / "Resources" / "Info.plist",
        "app.ceciliasnotes.page",
        "Mac NSUserActivityTypes",
    ),
    (
        CECILIAS / "CeciliasNotesShareExtension" / "Info.plist",
        "NSExtensionActivationSupportsText",
        "Share extension text activation",
    ),
]


def load_flows() -> dict[str, dict]:
    text = YAML_PATH.read_text(encoding="utf-8")
    flows: dict[str, dict] = {}
    current_id: str | None = None
    block: list[str] = []
    for line in text.splitlines():
        m = re.match(r"^\s+- id: (\S+)", line)
        if m:
            if current_id:
                flows[current_id] = "\n".join(block)
            current_id = m.group(1)
            block = [line]
        elif current_id:
            block.append(line)
    if current_id:
        flows[current_id] = "\n".join(block)
    return flows


def flow_status(block: str, device: str) -> str | None:
    m = re.search(rf"{device}: \{{ status: (\w+)", block)
    return m.group(1) if m else None


def resolve_path(rel: str) -> Path:
    if rel.startswith("CeciliasNotesMac") or rel.startswith("CeciliasNotesShareExtension"):
        return CECILIAS / rel
    if rel.startswith("CeciliasNotesWidget"):
        return CECILIAS / rel
    if rel.startswith("CeciliasNotes/CeciliasNotes/"):
        return CECILIAS / rel[len("CeciliasNotes/") :]
    if rel.startswith("CeciliasNotes/"):
        return CECILIAS / "CeciliasNotes" / rel[len("CeciliasNotes/") :]
    return APP_SRC / rel


def check_files(flow_id: str, block: str) -> list[str]:
    errors: list[str] = []
    m = re.search(r"files: \[(.*?)\]", block, re.DOTALL)
    if not m:
        return errors
    raw = m.group(1)
    for part in re.findall(r"[\w./]+", raw):
        path = resolve_path(part)
        if not path.exists():
            errors.append(f"{flow_id}: missing file {part}")
    return errors


def check_symbols(flow_id: str) -> list[str]:
    errors: list[str] = []
    for rel, symbol in REQUIRED_SYMBOLS.get(flow_id, []):
        path = resolve_path(rel)
        if not path.exists():
            errors.append(f"{flow_id}: missing {rel}")
            continue
        if symbol not in path.read_text(encoding="utf-8"):
            errors.append(f"{flow_id}: `{symbol}` not found in {rel}")
    return errors


def check_notifications(graph: dict) -> list[str]:
    errors: list[str] = []
    edges = graph.get("notifications", {}).get("edges", [])
    by_name = {n["name"]: n for n in edges}
    for name, poster_hint, observer_hint in NOTIFICATION_WIRING:
        entry = by_name.get(name)
        if not entry:
            errors.append(f"notification `{name}` missing from CODE_GRAPH")
            continue
        posted = " ".join(entry.get("posted_in", []))
        observed = " ".join(entry.get("observed_in", []))
        if poster_hint not in posted:
            errors.append(f"`{name}` poster missing ({poster_hint})")
        if observer_hint not in observed:
            errors.append(f"`{name}` observer missing ({observer_hint})")
    return errors


def main() -> int:
    flows = load_flows()
    errors: list[str] = []
    warnings: list[str] = []

    print("Integration wiring check (batches 11–14)\n")
    print(f"{'Flow':<35} {'iPad':<12} {'iPhone':<12} {'Mac':<12}")
    print("-" * 72)

    for flow_id in FLOW_IDS:
        block = flows.get(flow_id, "")
        if not block:
            errors.append(f"flow `{flow_id}` not in USER_FLOWS.yaml")
            continue
        ipad = flow_status(block, "ipad") or "—"
        iphone = flow_status(block, "iphone") or "—"
        mac = flow_status(block, "mac") or "—"
        print(f"{flow_id:<35} {ipad:<12} {iphone:<12} {mac:<12}")
        for dev in ("ipad", "iphone", "mac"):
            st = flow_status(block, dev)
            if st not in ("missing", "stub"):
                continue
            if flow_id.startswith("mac_capture.") and dev in ("ipad", "iphone"):
                continue
            if flow_id == "system.services_menu" and dev in ("ipad", "iphone"):
                continue
            if flow_id == "system.share_extension" and dev == "mac":
                continue
            errors.append(f"{flow_id} [{dev}] still {st}")
        errors.extend(check_files(flow_id, block))
        errors.extend(check_symbols(flow_id))

    graph = json.loads(GRAPH_PATH.read_text(encoding="utf-8"))
    edges = graph.get("notifications", {}).get("edges", [])
    errors.extend(check_notifications(graph))

    for path, needle, label in PLIST_CHECKS:
        if not path.exists():
            errors.append(f"{label}: plist missing at {path}")
        elif needle not in path.read_text(encoding="utf-8"):
            errors.append(f"{label}: `{needle}` not in {path.name}")

    # macQuickCaptureToggle has no observer in graph — known gap, warn only.
    mac_qc = next((n for n in edges if n["name"] == "macQuickCaptureToggle"), None)
    if mac_qc and not mac_qc.get("observed_in"):
        warnings.append("macQuickCaptureToggle has no observer (palette may use alternate path)")

    print()
    if warnings:
        print("Warnings:")
        for w in warnings:
            print(f"  ⚠ {w}")
        print()

    if errors:
        print("FAILED — wiring gaps:")
        for e in errors:
            print(f"  ✗ {e}")
        return 1

    print("PASSED — files, symbols, notifications, and plists look wired.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
