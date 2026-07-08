#!/usr/bin/env python3
"""
Lightweight Code Property Graph builder for the Cecilia's Notes Swift codebase.

Produces two artifacts consumed by humans and by LLM assistants opening the
project cold:
  - Documentation/CODE_GRAPH.json   : machine-readable graph
  - Documentation/CODE_GRAPH.md     : human-readable map (per-module summary,
                                      notification bus, hot files, entry points)

The graph is intentionally *lexical* (regex over Swift source) rather than a
full AST/CFG/PDG. It optimises for cheap, deterministic, no-toolchain runs so
it can be regenerated any time the codebase changes.

Nodes  : files, types (class/struct/enum/actor/protocol), notification names
Edges  : file -> imports, file -> declares type, type -> conforms to protocol,
         file -> posts notification, file -> observes notification,
         type -> references type (rough, best-effort)

Usage:
    python3 Documentation/tools/build_code_graph.py
"""

from __future__ import annotations

import json
import re
from collections import defaultdict
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
SRC_ROOTS = [
    ROOT / "CeciliasNotes" / "CeciliasNotes",
    ROOT / "CeciliasNotes" / "CeciliasNotesMac",
]
OUT_JSON = ROOT / "Documentation" / "CODE_GRAPH.json"
OUT_MD = ROOT / "Documentation" / "CODE_GRAPH.md"

# ---------------------------------------------------------------------------
# regexes
# ---------------------------------------------------------------------------

RE_IMPORT = re.compile(r"^\s*import\s+([A-Za-z_][\w.]*)", re.MULTILINE)
RE_DECL = re.compile(
    r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*"
    r"(class|struct|enum|actor|protocol)\s+([A-Za-z_]\w*)"
    r"(?:\s*<[^>]*>)?"
    r"(?:\s*:\s*([^\{\n]+))?",
    re.MULTILINE,
)
RE_EXTENSION = re.compile(
    r"^\s*extension\s+([A-Za-z_][\w.]*)"
    r"(?:\s*:\s*([^\{\n]+))?",
    re.MULTILINE,
)
RE_NOTIF_DECL = re.compile(
    r"static\s+let\s+([A-Za-z_]\w*)\s*=\s*Notification\.Name\(\s*\"([^\"]+)\"\s*\)"
)
# Also: Notification.Name("literal") inline
RE_NOTIF_INLINE = re.compile(r'Notification\.Name\(\s*"([^"]+)"\s*\)')
RE_POST = re.compile(
    r"NotificationCenter\.default\.post\(\s*name:\s*([^,\)]+)"
)
RE_OBSERVE = re.compile(
    r"NotificationCenter\.default\.(?:addObserver|publisher)\([^)]*(?:name:|forName:|for:)\s*([^,\)]+)"
)

PLATFORM_MODULES = {
    "SwiftUI", "UIKit", "AppKit", "Foundation", "Combine", "SwiftData",
    "CloudKit", "CoreData", "CoreGraphics", "CoreImage", "PencilKit",
    "PhotosUI", "PDFKit", "Vision", "VisionKit", "Speech", "AVFoundation",
    "AVKit", "MultipeerConnectivity", "WidgetKit", "UniformTypeIdentifiers",
    "CoreSpotlight", "OSLog", "os", "Network", "UserNotifications",
    "FoundationModels", "AppIntents", "Intents", "IntentsUI",
    "BackgroundTasks", "StoreKit", "ImageIO", "Accelerate", "Metal",
    "MetalKit", "GameKit", "MessageUI", "SafariServices",
}

# ---------------------------------------------------------------------------
# model
# ---------------------------------------------------------------------------

@dataclass
class FileNode:
    path: str            # repo-relative
    module: str          # top-level folder within source root
    target: str          # CeciliasNotes | CeciliasNotesMac
    imports: list[str] = field(default_factory=list)
    declared_types: list[str] = field(default_factory=list)
    extends: list[str] = field(default_factory=list)
    posts: list[str] = field(default_factory=list)
    observes: list[str] = field(default_factory=list)
    lines: int = 0

@dataclass
class TypeNode:
    name: str
    kind: str            # class|struct|enum|actor|protocol
    file: str
    conforms_to: list[str] = field(default_factory=list)

@dataclass
class NotificationEdge:
    name: str            # notification name symbol or string literal
    posted_in: list[str] = field(default_factory=list)
    observed_in: list[str] = field(default_factory=list)

# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------

def iter_swift_files() -> Iterable[Path]:
    for root in SRC_ROOTS:
        if not root.exists():
            continue
        # Sorted: rglob yields in filesystem order, which differs
        # between local APFS and CI runners — any output list built
        # in scan order (notification posters, conformances, …)
        # would otherwise churn between machines and trip the CI
        # freshness gate on identical sources.
        for p in sorted(root.rglob("*.swift")):
            if any(seg.startswith(".") for seg in p.parts):
                continue
            yield p


def module_for(path: Path) -> tuple[str, str]:
    """Return (target, module) — target is the Xcode target; module is the
    top-level source folder (App/Core/Features/DesignSystem/Resources/…)."""
    parts = path.relative_to(ROOT).parts
    target = parts[1]  # CeciliasNotes/{CeciliasNotes,CeciliasNotesMac}/...
    # For iOS: CeciliasNotes/CeciliasNotes/<module>/...
    # For Mac: CeciliasNotes/CeciliasNotesMac/<module or file>/...
    if len(parts) >= 4:
        module = parts[2]
    else:
        module = "(root)"
    return target, module


def scan_file(path: Path) -> tuple[FileNode, list[TypeNode]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    target, module = module_for(path)
    rel = str(path.relative_to(ROOT))

    node = FileNode(
        path=rel,
        module=module,
        target=target,
        lines=text.count("\n") + 1,
    )
    types: list[TypeNode] = []

    node.imports = sorted(set(RE_IMPORT.findall(text)))

    for m in RE_DECL.finditer(text):
        kind, name, conforms = m.group(1), m.group(2), (m.group(3) or "")
        conforms_list = [
            c.strip()
            for c in re.split(r"[,&]", conforms)
            if c.strip() and not c.strip().startswith("where")
        ]
        node.declared_types.append(name)
        types.append(TypeNode(name=name, kind=kind, file=rel, conforms_to=conforms_list))

    for m in RE_EXTENSION.finditer(text):
        base = m.group(1)
        node.extends.append(base)

    # Notification bus
    for m in RE_POST.finditer(text):
        node.posts.append(m.group(1).strip())
    for m in RE_OBSERVE.finditer(text):
        node.observes.append(m.group(1).strip())

    return node, types


def build_graph():
    files: list[FileNode] = []
    types: dict[str, TypeNode] = {}
    notif_defs: dict[str, dict] = {}   # notif slug -> {"symbol", "string", "declared_in"}
    posts_by_file: list[tuple[str, str]] = []       # (file, notif ref)
    observes_by_file: list[tuple[str, str]] = []    # (file, notif ref)

    for p in iter_swift_files():
        fn, ts = scan_file(p)
        files.append(fn)
        for t in ts:
            # last-writer wins on duplicate names across targets — fine, we
            # record the file so the graph still shows both if you grep.
            types[t.name] = t

        text = p.read_text(encoding="utf-8", errors="replace")
        for m in RE_NOTIF_DECL.finditer(text):
            symbol, literal = m.group(1), m.group(2)
            notif_defs[symbol] = {
                "symbol": symbol,
                "string": literal,
                "declared_in": str(p.relative_to(ROOT)),
            }
        for ref in fn.posts:
            posts_by_file.append((fn.path, ref))
        for ref in fn.observes:
            observes_by_file.append((fn.path, ref))

    # Resolve post/observe references to notification symbols (best effort:
    # match by the trailing dotted segment, e.g. ".macOpenSettings" ->
    # macOpenSettings). Unknown refs are kept as-is.
    def normalise(ref: str) -> str:
        ref = ref.strip()
        if ref.startswith("."):
            return ref[1:]
        # trailing identifier after the last dot
        return ref.split(".")[-1]

    notif_edges: dict[str, NotificationEdge] = {
        k: NotificationEdge(name=k) for k in notif_defs
    }
    for file, ref in posts_by_file:
        key = normalise(ref)
        if key not in notif_edges:
            notif_edges[key] = NotificationEdge(name=key)
        notif_edges[key].posted_in.append(file)
    for file, ref in observes_by_file:
        key = normalise(ref)
        if key not in notif_edges:
            notif_edges[key] = NotificationEdge(name=key)
        notif_edges[key].observed_in.append(file)

    return files, types, notif_defs, notif_edges


# ---------------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------------

def emit_json(files, types, notif_defs, notif_edges):
    payload = {
        "generated_by": "Documentation/tools/build_code_graph.py",
        "roots": [str(r.relative_to(ROOT)) for r in SRC_ROOTS if r.exists()],
        "counts": {
            "files": len(files),
            "types": len(types),
            "notifications_declared": len(notif_defs),
            "notification_symbols_referenced": len(notif_edges),
        },
        "files": [asdict(f) for f in sorted(files, key=lambda x: x.path)],
        "types": [asdict(t) for t in sorted(types.values(), key=lambda x: x.name)],
        "notifications": {
            "declarations": list(notif_defs.values()),
            "edges": [asdict(e) for e in sorted(notif_edges.values(), key=lambda x: x.name)],
        },
    }
    OUT_JSON.write_text(json.dumps(payload, indent=2))


def emit_markdown(files, types, notif_defs, notif_edges):
    by_target: dict[str, dict[str, list[FileNode]]] = defaultdict(lambda: defaultdict(list))
    for f in files:
        by_target[f.target][f.module].append(f)

    lines: list[str] = []
    w = lines.append

    w("# Code Property Graph")
    w("")
    w("_Auto-generated by `Documentation/tools/build_code_graph.py`. Do not edit by hand — regenerate after structural changes._")
    w("")
    w("This map is for any LLM (or human) opening the project cold. It answers:")
    w("- Where does each concern live?")
    w("- Which files talk to which via SwiftData, imports, or the `NotificationCenter` bus?")
    w("- Where are the entry points and the biggest files?")
    w("")
    w("Full machine-readable data: [`CODE_GRAPH.json`](CODE_GRAPH.json).")
    w("")

    # Counts
    w("## Snapshot")
    w("")
    w(f"- Swift files scanned: **{len(files)}**")
    w(f"- Types declared: **{len(types)}**")
    w(f"- `Notification.Name` declarations: **{len(notif_defs)}**")
    w(f"- Notification symbols referenced (post/observe): **{len(notif_edges)}**")
    w("")

    # Per-target module layout
    w("## Target layout")
    w("")
    for target in sorted(by_target):
        w(f"### `{target}`")
        w("")
        w("| Module | Files | Lines |")
        w("| --- | ---: | ---: |")
        module_totals = []
        for module, mfiles in sorted(by_target[target].items()):
            total_lines = sum(f.lines for f in mfiles)
            module_totals.append((module, len(mfiles), total_lines))
            w(f"| `{module}/` | {len(mfiles)} | {total_lines:,} |")
        w("")

    # Hot files (top 20 by line count) — useful when a bug lives in a fat file
    w("## Hot files (top 25 by lines)")
    w("")
    w("These are the largest files. When a symptom is diffuse, start here — the big ones own the most surface area.")
    w("")
    w("| Lines | File |")
    w("| ---: | --- |")
    for f in sorted(files, key=lambda x: -x.lines)[:25]:
        w(f"| {f.lines:,} | [`{f.path}`]({rel_from_docs(f.path)}) |")
    w("")

    # Notification bus — this is the app's message layer
    w("## Notification bus")
    w("")
    w("The app uses `NotificationCenter` as a lightweight cross-view/cross-service message layer. Declared symbols with post/observe callsites below. **Bold** = declared. Callsites are the resolved files that reference the symbol via `.name` shorthand or the fully-qualified path.")
    w("")
    w("| Symbol | Declared in | Posts | Observers |")
    w("| --- | --- | --- | --- |")
    decl_keys = set(notif_defs)
    for name in sorted(notif_edges):
        edge = notif_edges[name]
        decl = notif_defs.get(name)
        symbol = f"**`{name}`**" if name in decl_keys else f"`{name}`"
        decl_cell = f"[`{decl['declared_in']}`]({rel_from_docs(decl['declared_in'])})" if decl else "—"
        posts_cell = format_file_list(edge.posted_in)
        obs_cell = format_file_list(edge.observed_in)
        w(f"| {symbol} | {decl_cell} | {posts_cell} | {obs_cell} |")
    w("")

    # Protocol conformance clusters — where behaviour is wired
    w("## Protocol conformance clusters")
    w("")
    w("Types grouped by the protocols they conform to. Useful for finding all implementors of a role (delegate, environment key, feature capability).")
    w("")
    proto_to_types: dict[str, list[TypeNode]] = defaultdict(list)
    for t in types.values():
        for p in t.conforms_to:
            proto_to_types[p].append(t)
    for proto in sorted(proto_to_types):
        impls = proto_to_types[proto]
        if len(impls) < 2:
            continue
        w(f"- **`{proto}`** — {len(impls)} conformers: " +
          ", ".join(f"`{t.name}`" for t in sorted(impls, key=lambda x: x.name)[:12]) +
          ("" if len(impls) <= 12 else f", … +{len(impls) - 12}"))
    w("")

    # Entry points
    w("## Entry points")
    w("")
    w("Files that own app startup or top-level scene composition. Read these first if you're new.")
    w("")
    entry_hints = [
        ("iOS app", "CeciliasNotes/CeciliasNotes/App/CeciliasNotesApp.swift"),
        ("Mac app", "CeciliasNotes/CeciliasNotesMac/CeciliasNotesMacApp.swift"),
        ("Mac app delegate", "CeciliasNotes/CeciliasNotesMac/App/MacAppDelegate.swift"),
        ("iOS root", "CeciliasNotes/CeciliasNotes/App/RootView.swift"),
        ("Mac root", "CeciliasNotes/CeciliasNotesMac/MacRootView.swift"),
        ("Library (both)", "CeciliasNotes/CeciliasNotes/Features/Library/LibraryView.swift"),
        ("Editor (iOS)", "CeciliasNotes/CeciliasNotes/Features/Editor/EditorView.swift"),
        ("Editor (Mac)", "CeciliasNotes/CeciliasNotesMac/Editor/MacEditorView.swift"),
        ("Storage", "CeciliasNotes/CeciliasNotes/Core/Services/StorageService.swift"),
        ("CloudKit sync", "CeciliasNotes/CeciliasNotes/Core/Services/CloudSyncManager.swift"),
        ("Multipeer sync", "CeciliasNotes/CeciliasNotes/Core/Services/MultipeerSyncService.swift"),
        ("Personalisation", "CeciliasNotes/CeciliasNotes/Features/Onboarding/PersonalIdentity.swift"),
    ]
    for label, p in entry_hints:
        exists = (ROOT / p).exists()
        marker = "" if exists else "  _(missing — path drifted?)_"
        w(f"- **{label}** — [`{p}`]({rel_from_docs(p)}){marker}")
    w("")

    # Cross-target sharing summary
    w("## Cross-target sharing")
    w("")
    ios_files = [f for f in files if f.target == "CeciliasNotes"]
    mac_files = [f for f in files if f.target == "CeciliasNotesMac"]
    w(f"- iOS target files: **{len(ios_files)}**")
    w(f"- Mac target files: **{len(mac_files)}**")
    w("- The Mac target compiles most iOS files directly via `PBXFileSystemSynchronizedRootGroup` synced folders with per-file exceptions. Search the pbxproj for `PBXFileSystemSynchronizedBuildFileExceptionSet` to see the exclusion lists.")
    w("- Platform guards to look for: `#if canImport(UIKit)`, `#if canImport(AppKit)`, `#if os(iOS)`. Anything wrapped in these is asymmetric and worth an extra read when debugging cross-platform.")
    w("")

    OUT_MD.write_text("\n".join(lines))


def format_file_list(paths: list[str]) -> str:
    if not paths:
        return "—"
    uniq = sorted(set(paths))
    shown = uniq[:4]
    tail = "" if len(uniq) <= 4 else f", … +{len(uniq) - 4}"
    return ", ".join(f"[`{Path(p).name}`]({rel_from_docs(p)})" for p in shown) + tail


def rel_from_docs(repo_path: str) -> str:
    """Repo-relative path -> path relative to Documentation/CODE_GRAPH.md."""
    return "../" + repo_path


def main() -> None:
    files, types, notif_defs, notif_edges = build_graph()
    emit_json(files, types, notif_defs, notif_edges)
    emit_markdown(files, types, notif_defs, notif_edges)
    print(f"Wrote {OUT_JSON.relative_to(ROOT)}")
    print(f"Wrote {OUT_MD.relative_to(ROOT)}")
    print(f"  files={len(files)} types={len(types)} notif_declared={len(notif_defs)} notif_symbols={len(notif_edges)}")


if __name__ == "__main__":
    main()
