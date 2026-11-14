#!/usr/bin/env python3
"""Build Anki decks, printable index cards, and a CSV from Omarchy keybindings.

The source of truth is the Hyprland Lua files Omarchy ships under
/usr/share/omarchy/default/hypr/bindings plus the personal file
~/.config/hypr/bindings.lua. A snapshot of those files lives in
flashcards/source/. Re-run this script after `omarchy update`.

    python3 flashcards/generate.py
    python3 flashcards/generate.py --live
    python3 flashcards/generate.py --live --only-installed

--live reads the laptop paths. Without --only-installed, command-gated binds
(dictation, lazydocker) are included and tagged, because they are real bindings
in the files. --only-installed keeps a bind only when its program is on PATH.
"""

from __future__ import annotations

import argparse
import csv
import html
import shutil
import sqlite3
import subprocess
import sys
import zipfile
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import genanki
from weasyprint import HTML

from lua_subset import (
    Call,
    Dot,
    Interpreter,
    Lit,
    LuaError,
    LuaObject,
    MethodCall,
    Name,
    Node,
    Proxy,
    Table,
    UnOp,
    lua_ipairs,
    lua_pairs,
    lua_tostring,
    parse,
)

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
SOURCE = ROOT / "source"

FILE_ORDER = [
    "applications.lua",
    "clipboard.lua",
    "dictation.lua",
    "input-method.lua",
    "jis.lua",
    "media.lua",
    "tiling.lua",
    "utilities.lua",
]
CATEGORY_OF = {
    "applications.lua": "Applications",
    "clipboard.lua": "Clipboard",
    "dictation.lua": "Dictation",
    "input-method.lua": "Input method",
    "jis.lua": "JIS",
    "media.lua": "Media",
    "tiling.lua": "Tiling",
    "utilities.lua": "Utilities",
    "user-bindings.lua": "Personal",
}
CATEGORY_ORDER = [
    "Applications",
    "Clipboard",
    "Tiling",
    "Utilities",
    "Media",
    "Dictation",
    "Input method",
    "JIS",
    "Personal",
]
ACCENT = {
    "Applications": "#0284c7",
    "Clipboard": "#7c3aed",
    "Tiling": "#0369a1",
    "Utilities": "#b45309",
    "Media": "#0f766e",
    "Dictation": "#be123c",
    "Input method": "#4338ca",
    "JIS": "#a16207",
    "Personal": "#0369a1",
}

# XKB evdev keycodes (Hyprland `code:` numbers). 10 is the 1 key.
CODE_LABEL = {
    10: "1", 11: "2", 12: "3", 13: "4", 14: "5",
    15: "6", 16: "7", 17: "8", 18: "9", 19: "0",
    20: "−", 21: "=",
    34: "[", 35: "]",
    201: "F23",
}
XF86_LABEL = {
    "XF86AudioRaiseVolume": "Vol +",
    "XF86AudioLowerVolume": "Vol −",
    "XF86AudioMute": "Mute",
    "XF86AudioMicMute": "Mic mute",
    "XF86MonBrightnessUp": "Bright +",
    "XF86MonBrightnessDown": "Bright −",
    "XF86KbdBrightnessUp": "Kbd +",
    "XF86KbdBrightnessDown": "Kbd −",
    "XF86KbdLightOnOff": "Kbd light",
    "XF86TouchpadToggle": "Touchpad",
    "XF86TouchpadOn": "Pad on",
    "XF86TouchpadOff": "Pad off",
    "XF86AudioNext": "Next",
    "XF86AudioPlay": "Play",
    "XF86AudioPause": "Pause",
    "XF86AudioPrev": "Prev",
    "XF86Eject": "Eject",
    "XF86PowerOff": "Power",
    "XF86Calculator": "Calc",
}
PLAIN_LABEL = {
    "RETURN": "Enter",
    "SPACE": "Space",
    "ESCAPE": "Esc",
    "BACKSPACE": "Bksp",
    "DELETE": "Del",
    "Delete": "Del",
    "PRINT": "PrtSc",
    "TAB": "Tab",
    "HOME": "Home",
    "Home": "Home",
    "LEFT": "Left",
    "RIGHT": "Right",
    "UP": "Up",
    "DOWN": "Down",
    "SLASH": "/",
    "grave": "`",
    "comma": ",",
    "semicolon": ";",
    "PERIOD": ".",
    "Alt_R": "Right Alt",
    "mouse_down": "Wheel down",
    "mouse_up": "Wheel up",
}
MOUSE_LABEL = {272: "Left click", 273: "Right click", 274: "Middle click"}
MODIFIERS = {"SUPER", "SHIFT", "ALT", "CTRL"}
REGION_TITLES = {
    "--take-window": "Take the window",
    "--take-fullscreen": "Take the full screen",
    "--select-window next": "Select the next window",
    "--select-window prev": "Select the previous window",
    "--select-window left": "Select the window to the left",
    "--select-window right": "Select the window to the right",
    "--select-window up": "Select the window above",
    "--select-window down": "Select the window below",
}

STUDY_MODEL_ID = 1602450311
REF_MODEL_ID = 1602450312
STUDY_DECK_ID = 1602450411
REF_DECK_ID = 1602450412

PAGE_SIZES = {
    "3x5": ("5in", "3in"),
    "4x6": ("6in", "4in"),
}


@dataclass
class Binding:
    raw: str
    norm: str
    action: str
    category: str
    group: str | None
    source: str
    line: int
    kind: str
    detail: str
    conditions: list[str] = field(default_factory=list)
    personal: bool = False
    repeating: bool = False
    locked: bool = False
    seq: int = 0
    ordinal: int = 0
    parts: list[tuple[str, str]] = field(default_factory=list)

    @property
    def keys_text(self) -> str:
        return " + ".join(label for label, _role in self.parts)

    @property
    def tags(self) -> list[str]:
        tags = [slug(self.category)]
        group_tag = {
            "Essential application bindings": "essential",
            "Preinstalled apps": "preinstalled",
            "Volume, brightness, and hardware": "volume-hardware",
            "Precise volume and brightness": "precise",
            "Media controls": "media-controls",
            "Region picker": "region-picker",
        }.get(self.group or "")
        if group_tag:
            tags.append(group_tag)
        for cond in self.conditions:
            if cond == "preinstalled":
                tags.append("preinstalled")
            elif cond == "dictation":
                tags.append("conditional-dictation")
            elif cond.startswith("command:"):
                tags.append("conditional-" + slug(cond.split(":", 1)[1]))
        if self.personal:
            tags.append("personal")
        if self.category == "JIS":
            tags.append("jis")
        if self.kind == "region":
            tags.append("region-picker")
        if self.raw.startswith("switch:"):
            tags.append("hardware-switch")
        if "Apple" in self.raw:
            tags.append("apple")
        if "mouse" in self.raw:
            tags.append("mouse")
        if self.repeating:
            tags.append("repeats")
        if self.locked:
            tags.append("lock-screen")
        # Preserve order, drop duplicates.
        seen: dict[str, None] = {}
        for tag in tags:
            seen.setdefault(tag, None)
        return list(seen)


def slug(text: str) -> str:
    out = []
    for ch in text.lower():
        if ch.isalnum():
            out.append(ch)
        elif ch in " _/,":
            out.append("-")
    slug_text = "".join(out).strip("-")
    while "--" in slug_text:
        slug_text = slug_text.replace("--", "-")
    return slug_text or "untagged"


def normalize_keys(raw: str) -> str:
    parts = []
    for part in str(raw).split("+"):
        token = part.strip()
        if token.upper() in MODIFIERS:
            token = token.upper()
        parts.append(token)
    return " + ".join(parts)


def label_token(token: str) -> tuple[str, str]:
    if token in MODIFIERS:
        return token, "super" if token == "SUPER" else "mod"
    if token in XF86_LABEL:
        return XF86_LABEL[token], "key"
    if token in PLAIN_LABEL:
        return PLAIN_LABEL[token], "key"
    if token.startswith("code:"):
        number = int(token.split(":", 1)[1])
        return CODE_LABEL.get(number, f"code {number}"), "key"
    if token.startswith("mouse:"):
        number = int(token.split(":", 1)[1])
        return MOUSE_LABEL.get(number, f"Mouse {number}"), "key"
    if token.startswith("switch:"):
        _kind, state, name = token.split(":", 2)
        if "Apple" in name:
            base = "Apple lid"
        elif "Lid" in name:
            base = "Lid"
        else:
            base = name
        return f"{base} {'close' if state == 'on' else 'open'}", "key"
    return token, "key"


def section_group(comment: str) -> str | None:
    text = " ".join(comment.strip().split())
    low = text.lower().rstrip(".")
    if low.startswith("essential"):
        return "Essential application bindings"
    if "preinstalled" in low:
        return "Preinstalled apps"
    if low.startswith("volume, brightness"):
        return "Volume, brightness, and hardware"
    if low.startswith("precise volume"):
        return "Precise volume and brightness"
    if low == "media controls":
        return "Media controls"
    return None


def condition_label(expr: Node) -> str | None:
    text = expr_text(expr)
    if "dictation_installed" in text:
        return "dictation"
    if "cmd_present" in text:
        command = _call_string_arg(expr, "cmd_present")
        return f"command:{command}" if command else "command"
    if "preinstalled_bindings_enabled" in text:
        return "preinstalled"
    return None


def expr_text(expr: Node) -> str:
    if isinstance(expr, Name):
        return expr.name
    if isinstance(expr, Lit):
        return repr(expr.value)
    if isinstance(expr, Dot):
        return expr_text(expr.obj) + "." + expr.field
    if isinstance(expr, Call):
        return expr_text(expr.func) + "(" + ",".join(expr_text(arg) for arg in expr.args) + ")"
    if isinstance(expr, MethodCall):
        return expr_text(expr.obj) + ":" + expr.method + "()"
    if isinstance(expr, UnOp):
        return expr.op + " " + expr_text(expr.operand)
    if hasattr(expr, "op") and hasattr(expr, "left"):
        return expr_text(expr.left) + expr.op + expr_text(expr.right)
    return ""


def _call_string_arg(expr: Node, name: str) -> str | None:
    nodes = [expr]
    while nodes:
        node = nodes.pop()
        if isinstance(node, Call):
            func = expr_text(node.func)
            if func.endswith(name) and node.args and isinstance(node.args[0], Lit) and isinstance(node.args[0].value, str):
                return node.args[0].value
            nodes.extend(node.args)
            nodes.append(node.func)
        elif isinstance(node, UnOp):
            nodes.append(node.operand)
        elif hasattr(node, "left"):
            nodes.append(node.left)
            nodes.append(node.right)
    return None


def table_dict(value: Table | None) -> dict[Any, Any]:
    if not isinstance(value, Table):
        return {}
    return value.as_dict()


def action_bits(action: object) -> list[str]:
    if isinstance(action, str):
        return [action]
    if isinstance(action, Table):
        data = action.as_dict()
        bits = []
        for key in ("webapp", "launch", "omarchy", "tui", "menu", "panel", "audio", "brightness", "ipc"):
            if key not in data or isinstance(data[key], bool):
                continue
            shown = data[key]
            if key == "panel" and isinstance(shown, str) and shown.startswith("omarchy."):
                shown = shown.split(".", 1)[1]
            bits.append(f"{key}: {shown}")
        return bits
    return []


def title_for(description: object, action: object, raw_keys: str = "") -> str:
    if isinstance(description, str) and description.strip():
        title = description.strip()
    elif isinstance(action, str):
        if "lid-close" in action:
            title = "Close the lid"
        elif "clamshell" in action:
            title = "Open the lid"
        else:
            title = action
    else:
        title = "Unnamed binding"
    if "Apple" in raw_keys and title in {"Close the lid", "Open the lid"}:
        title += " (Apple SMC)"
    return title


def join_sentences(parts: list[str]) -> str:
    sentences = []
    for part in parts:
        text = " ".join(part.split())
        if not text:
            continue
        if text[-1] not in ".!?":
            text += "."
        sentences.append(text)
    return " ".join(sentences)


def disambiguate(bindings: list[Binding]) -> None:
    """Give colliding study fronts a hint when they are not the same command."""
    grouped: dict[str, list[Binding]] = defaultdict(list)
    for binding in bindings:
        grouped[binding.action].append(binding)
    for items in grouped.values():
        if len(items) < 2:
            continue
        hints = [_target_hint(item) for item in items]
        if len({hint for hint in hints if hint}) < 2:
            continue
        for binding, hint in zip(items, hints):
            if hint:
                binding.action = f"{binding.action} ({hint})"


def _target_hint(binding: Binding) -> str | None:
    detail = binding.detail
    if detail.startswith("webapp:"):
        return "web app"
    if detail.startswith("panel:"):
        name = detail.split()[1].rstrip(".,")
        return f"{name} panel"
    if detail.startswith("tui:"):
        return "terminal UI"
    return None


class Recorder:
    def __init__(self) -> None:
        self.bindings: list[Binding] = []
        self.skipped: list[tuple[str, str, str]] = []
        self.category = ""
        self.source = ""
        self.group: str | None = None
        self.pending_note: str | None = None
        self.conditions: list[str] = []
        self._seq = 0
        self.line = 1
        self.per_file: dict[str, int] = defaultdict(int)

    def on_comment(self, text: str) -> None:
        self.pending_note = None
        group = section_group(text)
        if group:
            self.group = group
            return
        stripped = " ".join(text.strip().split())
        if stripped.startswith("Launch ") or "instead" in stripped.lower():
            self.pending_note = stripped.rstrip(".")

    def on_condition(self, expr: Node, entering: bool) -> None:
        label = condition_label(expr) or ""
        if entering:
            self.conditions.append(label)
        elif self.conditions:
            self.conditions.pop()

    def _notes(self, options: dict[Any, Any], extra: list[str]) -> list[str]:
        notes = list(extra)
        if self.pending_note:
            notes.append(self.pending_note + ".")
            self.pending_note = None
        if options.get("repeating") is True:
            notes.append("Repeats while held.")
        if options.get("locked") is True:
            notes.append("Works on the lock screen.")
        if options.get("mouse") is True:
            notes.append("Hold and drag.")
        return notes

    def _context_notes(self, kind: str, raw: str) -> list[str]:
        notes = []
        if "dictation" in self.conditions:
            notes.append("Only while a dictation backend is installed.")
        for cond in self.conditions:
            if cond.startswith("command:"):
                notes.append(f"Only while {cond.split(':', 1)[1]} is installed.")
        if kind == "region":
            notes.append("Only while the screenshot region picker is open.")
        if self.category == "JIS":
            notes.append("JIS keyboards only. The plus key is Shift+; on that layout.")
        if "Apple" in raw:
            notes.append("Apple Silicon lid switch. This Dell does not send it.")
        if "F23" in raw or "code:201" in raw:
            notes.append("F23 is Hyprland code 201, the same menu as Super+Space.")
        return notes

    def add(self, kind: str, raw: str, action_title: str, detail_parts: list[str], options: dict[Any, Any], extra_notes: list[str] | None = None, group: str | None = None) -> Binding:
        notes = self._notes(options, extra_notes or [])
        notes.extend(self._context_notes(kind, raw))
        # The command string is already the title for a nil description.
        detail_parts = [part for part in detail_parts if part and part != action_title]
        detail = join_sentences([*detail_parts, *notes])
        self._seq += 1
        binding = Binding(
            raw=raw,
            norm=normalize_keys(raw),
            action=action_title,
            category=self.category,
            group=group if group is not None else self.group,
            source=self.source,
            line=self.line,
            kind=kind,
            detail=detail,
            conditions=[c for c in self.conditions if c],
            repeating=options.get("repeating") is True,
            locked=options.get("locked") is True,
            seq=self._seq,
            parts=[label_token(part) for part in normalize_keys(raw).split(" + ")],
        )
        self.bindings.append(binding)
        self.per_file[self.source] += 1
        return binding

    def bind(self, keys: str, description: object = None, action: object = None, options: object = None) -> None:
        opts = table_dict(options if isinstance(options, Table) else None)
        self.add("bind", str(keys), title_for(description, action, str(keys)), action_bits(action), opts)

    def rebind(self, keys: str, description: object = None, action: object = None, options: object = None) -> None:
        opts = table_dict(options if isinstance(options, Table) else None)
        notes = ["Personal binding."]
        fresh = self._prototype(str(keys), title_for(description, action, str(keys)), action_bits(action), opts, notes)
        fresh.personal = True
        matches = [b for b in self.bindings if b.norm == fresh.norm]
        if not matches:
            fresh.category = "Personal"
            fresh.seq = self._seq
            self.bindings.append(fresh)
            self.per_file[self.source] += 1
            return
        first = matches[0]
        fresh.category = first.category
        fresh.group = first.group
        fresh.seq = first.seq
        fresh.conditions = list(first.conditions)
        index = self.bindings.index(first)
        self.bindings[index] = fresh
        for extra in matches[1:]:
            self.bindings.remove(extra)
            self.skipped.append((extra.norm, extra.action, "removed because o.rebind replaced this chord"))

    def _prototype(self, raw: str, action_title: str, detail_parts: list[str], options: dict[Any, Any], extra_notes: list[str]) -> Binding:
        # add() also appends; build a binding without using that counter twice.
        # rebind wants the same shape, so call add and pop.
        binding = self.add("bind", raw, action_title, detail_parts, options, extra_notes)
        self.bindings.pop()
        self.per_file[self.source] -= 1
        return binding

    def bind_toggle(self, keys: str, description: object = None, name: object = None, options: object = None) -> None:
        opts = table_dict(options if isinstance(options, Table) else None)
        extra = [f"Toggles {name}."] if name else []
        self.add("toggle", str(keys), title_for(description, name, str(keys)), [], opts, extra)

    def bind_hold(self, keys: str, press_desc: object = None, press_action: object = None, release_desc: object = None, release_action: object = None, options: object = None) -> None:
        opts = table_dict(options if isinstance(options, Table) else None)
        extra = []
        if isinstance(release_desc, str) and release_desc.strip():
            extra.append(f"Release: {release_desc.strip()}")
        title = press_desc if isinstance(press_desc, str) and press_desc.strip() else "Hold"
        self.add("hold", str(keys), str(title), action_bits(press_action), opts, extra)

    def unbind(self, keys: str) -> None:
        norm = normalize_keys(str(keys))
        kept = []
        for binding in self.bindings:
            if binding.norm == norm:
                self.skipped.append((binding.norm, binding.action, "removed by hl.unbind"))
            else:
                kept.append(binding)
        self.bindings = kept

    def region_bind(self, keys: str, action: object) -> object:
        command = ""
        if isinstance(action, Proxy) and action.args:
            for arg in action.args:
                if isinstance(arg, str):
                    command = arg
        title = "Region picker"
        for flag, label in REGION_TITLES.items():
            if flag in command:
                title = label
                break
        self.add(
            "region",
            str(keys),
            title,
            [command] if command else [],
            {},
            group="Region picker",
        )
        return KeybindHandle()


class KeybindHandle:
    def set_enabled(self, _enabled: object) -> None:
        return None

    def __str__(self) -> str:
        return "HL.Keybind(active)"


class IOFile:
    def __init__(self, text: str):
        self.lines = text.splitlines()
        self.pos = 0

    def read(self, mode: str = "*l") -> str | None:
        if mode == "*l":
            if self.pos >= len(self.lines):
                return None
            line = self.lines[self.pos]
            self.pos += 1
            return line
        return None

    def close(self) -> bool:
        return True


class Options:
    def __init__(self, include_optional: bool, no_preinstalled: bool):
        self.include_optional = include_optional
        self.no_preinstalled = no_preinstalled


def load_all(bindings_dir: Path, user_bindings: Path | None, options: Options) -> Recorder:
    files: list[tuple[Path, str]] = []
    for name in FILE_ORDER:
        path = bindings_dir / name
        if path.exists():
            files.append((path, CATEGORY_OF[name]))
    known = set(FILE_ORDER) | {"user-bindings.lua", "bindings.lua"}
    for path in sorted(bindings_dir.glob("*.lua")):
        if path.name not in known:
            files.append((path, path.stem.replace("-", " ").title()))

    recorder = Recorder()
    state: dict[str, Interpreter | None] = {"interp": None}

    def at_line(method: str, args: tuple[object, ...]) -> object:
        interp = state["interp"]
        if interp is not None:
            recorder.line = interp.line
        return getattr(recorder, method)(*args)

    o = LuaObject("o")
    hl = LuaObject("hl")
    io_obj = LuaObject("io")
    keyboard = LuaObject("keyboard")

    def cmd_present(name: object) -> bool:
        if options.include_optional:
            return True
        return shutil.which(str(name)) is not None

    def popen(cmd: object, _mode: str = "r") -> IOFile:
        command = str(cmd)
        if options.include_optional and "omarchy-default-dictation" in command:
            return IOFile("whisper\n")
        try:
            proc = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=2, check=False)
            return IOFile(proc.stdout or "")
        except (OSError, subprocess.TimeoutExpired):
            return IOFile("")

    def require(name: object) -> LuaObject:
        if name == "default.hypr.keyboard":
            return keyboard
        raise LuaError(f"module '{name}' is not available")

    def hl_on(event: object, fn: object) -> None:
        if event == "layer.opened" and hasattr(fn, "invoke"):
            layer = Table()
            layer.set("namespace", "selection")
            fn.invoke([layer])  # type: ignore[attr-defined]

    o.set("bind", lambda *args: at_line("bind", args))
    o.set("rebind", lambda *args: at_line("rebind", args))
    o.set("bind_toggle", lambda *args: at_line("bind_toggle", args))
    o.set("bind_hold", lambda *args: at_line("bind_hold", args))
    o.set("preinstalled_bindings_enabled", lambda: not options.no_preinstalled)
    o.set("cmd_present", cmd_present)
    o.set("cmd_missing", lambda name: not cmd_present(name))
    hl.set("bind", lambda *args: at_line("region_bind", args))
    hl.set("unbind", lambda keys: at_line("unbind", (keys,)))
    hl.set("on", hl_on)
    io_obj.set("popen", popen)
    keyboard.set("jis", lambda: True)

    globals_dict = {
        "o": o,
        "hl": hl,
        "io": io_obj,
        "tostring": lua_tostring,
        "pairs": lua_pairs,
        "ipairs": lua_ipairs,
        "require": require,
        "print": lambda *_args: None,
        "type": lambda value: type(value).__name__,
    }

    def run_file(path: Path) -> None:
        source = path.read_text(encoding="utf-8")
        recorder.category = CATEGORY_OF.get(path.name, path.stem.replace("-", " ").title())
        recorder.source = path.name
        recorder.group = None
        recorder.pending_note = None
        recorder.conditions = []
        interp = Interpreter(str(path), source, globals_dict)
        interp.on_comment = recorder.on_comment
        interp.on_condition = recorder.on_condition
        state["interp"] = interp
        interp.run(parse(source, str(path)))

    for path, _category in files:
        run_file(path)
    if user_bindings is not None and user_bindings.exists():
        run_file(user_bindings)
    return recorder


def assign_ordinals(bindings: list[Binding]) -> None:
    grouped: dict[str, list[Binding]] = defaultdict(list)
    for binding in bindings:
        grouped[binding.norm].append(binding)
    for items in grouped.values():
        items.sort(key=lambda item: item.seq)
        for index, item in enumerate(items):
            item.ordinal = index


def sort_bindings(bindings: list[Binding]) -> list[Binding]:
    order = {name: index for index, name in enumerate(CATEGORY_ORDER)}
    return sorted(bindings, key=lambda b: (order.get(b.category, 99), b.seq))


def commented_examples(path: Path) -> list[str]:
    found = []
    if not path.exists():
        return found
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        body = stripped[2:].strip() if stripped.startswith("--") else ""
        if body.startswith(("o.bind(", "o.bind_toggle(", "o.bind_hold(", "o.rebind(", "hl.unbind(")):
            found.append(body)
    return found


def validate(bindings: list[Binding], per_file: dict[str, int]) -> None:
    expected = {
        "applications.lua": 30,
        "clipboard.lua": 5,
        "dictation.lua": 2,
        "input-method.lua": 3,
        "jis.lua": 1,
        "media.lua": 30,
        "tiling.lua": 109,
        "utilities.lua": 78,
    }
    problems = []
    for name, count in expected.items():
        # rebind does not change per_file (the prototype is popped). User file
        # adds nothing when both rebinds match. per_file counts additions.
        if per_file.get(name, 0) != count:
            problems.append(f"{name}: parsed {per_file.get(name, 0)}, expected {count}")
    if len(bindings) != sum(expected.values()):
        problems.append(f"card count {len(bindings)} != {sum(expected.values())}")
    by_norm = {b.norm: b for b in bindings}
    grok_bot = next((b for b in bindings if b.norm == normalize_keys("SUPER + SHIFT + ALT + A")), None)
    grok = next((b for b in bindings if b.norm == normalize_keys("SUPER + SHIFT + A")), None)
    if grok_bot is None or grok_bot.action != "Grok Bot":
        problems.append(f"SUPER+SHIFT+ALT+A should be Grok Bot, got {grok_bot}")
    if grok is None or grok.action != "Grok" or "grok.com" not in grok.detail:
        problems.append(f"SUPER+SHIFT+A should be the Grok web app, got {grok}")
    if any("ChatGPT" in b.action for b in bindings):
        problems.append("ChatGPT binding was not replaced")
    if not any(b.category == "JIS" for b in bindings):
        problems.append("JIS binding missing")
    workspaces = [b for b in bindings if b.action.startswith("Switch to workspace ")]
    if len(workspaces) != 10:
        problems.append(f"expected 10 workspace switches, got {len(workspaces)}")
    panels = [b for b in bindings if b.action.startswith("Bar panel ")]
    if len(panels) != 9:
        problems.append(f"expected 9 bar panels, got {len(panels)}")
    regions = [b for b in bindings if b.kind == "region"]
    if len(regions) != 8:
        problems.append(f"expected 8 region-picker binds, got {len(regions)}")
    if not any(b.category == "Dictation" for b in bindings):
        problems.append("dictation bindings missing")
    if not any("lazydocker" in b.detail or "conditional-lazydocker" in b.tags for b in bindings):
        problems.append("lazydocker binding missing")
    unknown = []
    for binding in bindings:
        for label, _role in binding.parts:
            if label.startswith(("code ", "code:", "XF86", "mouse:", "switch:")):
                unknown.append(f"{binding.raw} -> {label}")
        if not binding.action:
            problems.append(f"empty action for {binding.raw}")
    if unknown:
        problems.append("unlabeled keys: " + ", ".join(unknown))
    guids = [note_guid("study", b) for b in bindings] + [note_guid("reference", b) for b in bindings]
    if len(guids) != len(set(guids)):
        problems.append("GUID collision")
    if problems:
        raise SystemExit("Binding check failed:\n- " + "\n- ".join(problems))
    # Silence unused in case the dict form is handy while debugging.
    _ = by_norm


def note_guid(kind: str, binding: Binding) -> str:
    return genanki.guid_for("omarchy-keybinding-v1", kind, binding.norm, str(binding.ordinal))


def keys_html(binding: Binding) -> str:
    bits = []
    for index, (label, role) in enumerate(binding.parts):
        plus = '<span class="plus">+</span>' if index else ""
        bits.append(
            f'<span class="chord">{plus}<span class="key {role}">{html.escape(label)}</span></span>'
        )
    return "".join(bits)


def subtitle(binding: Binding) -> str:
    bits = []
    if binding.group:
        bits.append(binding.group)
    chips = []
    if binding.personal:
        chips.append("Personal")
    if binding.category == "JIS":
        chips.append("JIS keyboard")
    if any(c == "dictation" or c.startswith("command:") for c in binding.conditions):
        chips.append("If installed")
    if binding.kind == "region" and binding.group != "Region picker":
        chips.append("Region picker")
    if "Apple" in binding.raw:
        chips.append("Apple")
    for chip in chips:
        if binding.group and chip.lower() in binding.group.lower():
            continue
        bits.append(chip)
    return " · ".join(bits)


def size_class(text: str) -> str:
    if len(text) <= 24:
        return "s"
    if len(text) <= 40:
        return "m"
    return "l"


ANKI_CSS = """
.card {
  background: #070a12;
  color: #f8fafc;
  font-family: "Liberation Sans", "Noto Sans", sans-serif;
  padding: 28px 22px;
  text-align: center;
  line-height: 1.25;
}
.cat {
  color: #38bdf8;
  letter-spacing: 0.14em;
  font-size: 12px;
  font-weight: 700;
  text-transform: uppercase;
}
.sub { color: #94a3b8; font-size: 13px; margin-top: 6px; }
.action { font-size: 30px; font-weight: 800; margin: 26px 0 18px; }
.prompt {
  color: #64748b;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  font-size: 12px;
  margin-top: 8px;
}
.keys { margin: 22px 0; line-height: 2.2; }
.chord { display: inline-flex; align-items: center; gap: 6px; margin: 3px 4px; }
.key {
  display: inline-block;
  font-family: "JetBrains Mono", "Liberation Mono", monospace;
  font-weight: 700;
  font-size: 18px;
  color: #f8fafc;
  background: #19243b;
  border: 1px solid #2f3e5c;
  border-radius: 6px;
  padding: 4px 10px;
  margin: 3px 1px;
  vertical-align: middle;
}
.key.super { color: #38bdf8; background: #1e293b; border-color: #38bdf8; }
.plus {
  font-family: "JetBrains Mono", "Liberation Mono", monospace;
  color: #475569;
  font-weight: 700;
  margin: 0 4px;
}
.detail { color: #94a3b8; font-size: 15px; margin-top: 14px; }
.small .key { font-size: 14px; }
"""

STUDY_FIELDS = [
    {"name": "Action"},
    {"name": "Category"},
    {"name": "Subtitle"},
    {"name": "Keys"},
    {"name": "KeysHTML"},
    {"name": "Detail"},
]


def study_model() -> genanki.Model:
    # Fields are HTML-escaped in make_note. {{text:}} would be safer in Anki, but
    # genanki decides which cards to emit with Chevron, which does not treat
    # {{text:Field}} as a field and then drops any note with an empty subtitle.
    return genanki.Model(
        STUDY_MODEL_ID,
        "Omarchy Keybinding",
        fields=STUDY_FIELDS,
        templates=[
            {
                "name": "Action to keys",
                "qfmt": '<div class="cat">{{Category}}</div>'
                "{{#Subtitle}}<div class=\"sub\">{{Subtitle}}</div>{{/Subtitle}}"
                '<div class="action">{{Action}}</div>'
                '<div class="prompt">Which keys?</div>',
                "afmt": '<div class="cat">{{Category}}</div>'
                "{{#Subtitle}}<div class=\"sub\">{{Subtitle}}</div>{{/Subtitle}}"
                '<div class="keys">{{KeysHTML}}</div>'
                "{{#Detail}}<div class=\"detail\">{{Detail}}</div>{{/Detail}}",
            },
            {
                "name": "Keys to action",
                "qfmt": '<div class="cat">{{Category}}</div>'
                "{{#Subtitle}}<div class=\"sub\">{{Subtitle}}</div>{{/Subtitle}}"
                '<div class="keys">{{KeysHTML}}</div>'
                '<div class="prompt">What does this do?</div>',
                "afmt": '<div class="keys small">{{KeysHTML}}</div>'
                '<div class="action">{{Action}}</div>'
                "{{#Detail}}<div class=\"detail\">{{Detail}}</div>{{/Detail}}"
                '<div class="cat">{{Category}}</div>',
            },
        ],
        css=ANKI_CSS,
    )


def reference_model() -> genanki.Model:
    front = (
        '<div class="cat">{{Category}}</div>'
        "{{#Subtitle}}<div class=\"sub\">{{Subtitle}}</div>{{/Subtitle}}"
        '<div class="keys">{{KeysHTML}}</div>'
        '<div class="action">{{Action}}</div>'
        "{{#Detail}}<div class=\"detail\">{{Detail}}</div>{{/Detail}}"
    )
    return genanki.Model(
        REF_MODEL_ID,
        "Omarchy Keybinding Reference",
        fields=STUDY_FIELDS,
        templates=[{"name": "Reference", "qfmt": front, "afmt": front}],
        css=ANKI_CSS,
    )


def make_note(model: genanki.Model, binding: Binding, kind: str) -> genanki.Note:
    return genanki.Note(
        model=model,
        fields=[
            html.escape(binding.action),
            html.escape(binding.category),
            html.escape(subtitle(binding)),
            html.escape(binding.keys_text),
            keys_html(binding),
            html.escape(binding.detail),
        ],
        tags=binding.tags,
        guid=note_guid(kind, binding),
    )


def write_apkg(bindings: list[Binding], path: Path) -> None:
    study = genanki.Deck(STUDY_DECK_ID, "Omarchy Keybindings")
    study.description = "Action on the front, key combo on the back, plus the reverse card. Omarchy 4.5 keybindings."
    reference = genanki.Deck(REF_DECK_ID, "Omarchy Keybindings — Reference")
    reference.description = "One face: key combo, what it does, and the category."
    study_notes = study_model()
    reference_notes = reference_model()
    for binding in bindings:
        study.add_note(make_note(study_notes, binding, "study"))
        reference.add_note(make_note(reference_notes, binding, "reference"))
    genanki.Package([study, reference]).write_to_file(path)


def write_csv(bindings: list[Binding], path: Path) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["keys", "action", "category", "group", "detail", "tags", "raw_keys", "source", "line", "personal"])
        for binding in bindings:
            writer.writerow([
                binding.keys_text,
                binding.action,
                binding.category,
                binding.group or "",
                binding.detail,
                " ".join(binding.tags),
                binding.raw,
                binding.source,
                binding.line,
                "yes" if binding.personal else "no",
            ])


PRINT_CSS = """
@font-face {
  font-family: "Card Sans";
  src: url("file://__SANS__");
  font-weight: 400;
}
@font-face {
  font-family: "Card Sans";
  src: url("file://__SANS_BOLD__");
  font-weight: 700;
}
@font-face {
  font-family: "Card Mono";
  src: url("file://__MONO__");
  font-weight: 700;
}
@page { size: __W__ __H__; margin: 0; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: white; }
body { font-size: __BASE__; }
.card {
  width: __W__;
  height: __H__;
  position: relative;
  background: white;
  overflow: hidden;
  break-after: page;
  page-break-after: always;
}
.card:last-child { break-after: auto; page-break-after: auto; }
.rule {
  position: absolute;
  top: 0.16in;
  left: 0.22in;
  right: 0.22in;
  height: 3.5px;
  background: var(--accent);
  border-radius: 2px;
}
.cat {
  position: absolute;
  top: 0.28in;
  left: 0.24in;
  right: 0.95in;
  font-family: "Card Sans", "Liberation Sans", sans-serif;
  font-weight: 700;
  font-size: 0.72em;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: var(--accent);
}
.sub {
  position: absolute;
  top: 0.50in;
  left: 0.24in;
  right: 0.24in;
  font-family: "Card Sans", "Liberation Sans", sans-serif;
  font-size: 0.62em;
  color: #64748b;
}
.num {
  position: absolute;
  top: 0.28in;
  right: 0.24in;
  font-family: "Card Mono", "JetBrains Mono", monospace;
  font-size: 0.58em;
  font-weight: 700;
  color: #94a3b8;
}
.center {
  position: absolute;
  top: 0.78in;
  bottom: 0.36in;
  left: 0.22in;
  right: 0.22in;
  display: flex;
  align-items: center;
  justify-content: center;
  text-align: center;
}
.action {
  font-family: "Card Sans", "Liberation Sans", sans-serif;
  font-weight: 700;
  color: #0f172a;
  line-height: 1.15;
  hyphens: none;
}
.action.s { font-size: 1.85em; }
.action.m { font-size: 1.38em; }
.action.l { font-size: 1.12em; }
.prompt {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0.14in;
  text-align: center;
  font-family: "Card Sans", "Liberation Sans", sans-serif;
  font-size: 0.62em;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: #94a3b8;
}
.keys {
  width: 100%;
  display: flex;
  flex-wrap: wrap;
  gap: 0.22em 0.12em;
  align-items: center;
  justify-content: center;
}
.chord {
  display: inline-flex;
  align-items: center;
  gap: 0.28em;
}
.key {
  font-family: "Card Mono", "JetBrains Mono", monospace;
  font-weight: 700;
  font-size: 0.92em;
  color: #0f172a;
  background: #f8fafc;
  border: 1.5px solid #94a3b8;
  border-radius: 5px;
  padding: 0.16em 0.40em 0.12em;
  line-height: 1.15;
}
.key.super {
  color: #0369a1;
  background: #e0f2fe;
  border-color: #0284c7;
}
.plus {
  font-family: "Card Mono", "JetBrains Mono", monospace;
  font-weight: 700;
  color: #94a3b8;
  font-size: 0.85em;
}
.stack {
  position: absolute;
  top: 0.74in;
  bottom: 0.14in;
  left: 0.22in;
  right: 0.22in;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  justify-content: center;
  gap: 0.08in;
  text-align: center;
}
.stack .action { margin: 0; }
.detail {
  font-family: "Card Sans", "Liberation Sans", sans-serif;
  font-size: 0.66em;
  line-height: 1.28;
  color: #475569;
  max-width: 100%;
  overflow-wrap: anywhere;
  hyphens: none;
}
"""


def print_css(width: str, height: str) -> str:
    base = "12.5pt" if width == "5in" else "15.5pt"
    sans = "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"
    sans_bold = "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"
    mono = "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Bold.ttf"
    if not Path(mono).exists():
        mono = "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf"
    css = PRINT_CSS
    for token, value in (
        ("__SANS__", sans),
        ("__SANS_BOLD__", sans_bold),
        ("__MONO__", mono),
        ("__W__", width),
        ("__H__", height),
        ("__BASE__", base),
    ):
        css = css.replace(token, value)
    return css


def card_shell(binding: Binding, number: int, total: int, inner: str, prompt: str = "") -> str:
    accent = ACCENT.get(binding.category, "#0369a1")
    sub = subtitle(binding)
    sub_html = f'<div class="sub">{html.escape(sub)}</div>' if sub else ""
    prompt_html = f'<div class="prompt">{prompt}</div>' if prompt else ""
    return (
        f'<article class="card" style="--accent:{accent}">'
        f'<div class="rule"></div>'
        f'<div class="cat">{html.escape(binding.category)}</div>'
        f"{sub_html}"
        f'<div class="num">{number} / {total}</div>'
        f"{inner}"
        f"{prompt_html}"
        f"</article>"
    )


def study_front(binding: Binding, number: int, total: int) -> str:
    inner = (
        f'<div class="center"><div class="action {size_class(binding.action)}">'
        f"{html.escape(binding.action)}</div></div>"
    )
    return card_shell(binding, number, total, inner, "Which keys?")


def study_back(binding: Binding, number: int, total: int) -> str:
    inner = f'<div class="center"><div class="keys">{keys_html(binding)}</div></div>'
    return card_shell(binding, number, total, inner, "")


def reference_face(binding: Binding, number: int, total: int) -> str:
    detail = f'<div class="detail">{html.escape(binding.detail)}</div>' if binding.detail else ""
    inner = (
        '<div class="stack">'
        f'<div class="keys">{keys_html(binding)}</div>'
        f'<div class="action {size_class(binding.action)}">{html.escape(binding.action)}</div>'
        f"{detail}"
        "</div>"
    )
    return card_shell(binding, number, total, inner, "")


def write_pdf(pages: list[str], path: Path, size_name: str) -> None:
    width, height = PAGE_SIZES[size_name]
    document = (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
        f"<style>{print_css(width, height)}</style></head><body>"
        + "".join(pages)
        + "</body></html>"
    )
    HTML(string=document, base_url=str(ROOT)).write_pdf(path)


def verify_apkg(path: Path, binding_count: int) -> tuple[int, int]:
    with zipfile.ZipFile(path) as bundle:
        names = bundle.namelist()
        collection = next(name for name in names if name.startswith("collection.anki"))
        payload = bundle.read(collection)
    temp = path.with_suffix(".collection-check.anki2")
    temp.write_bytes(payload)
    try:
        con = sqlite3.connect(temp)
        notes = con.execute("select count(*) from notes").fetchone()[0]
        cards = con.execute("select count(*) from cards").fetchone()[0]
        con.close()
    finally:
        temp.unlink()
    if notes != binding_count * 2:
        raise SystemExit(f"apkg notes {notes} != {binding_count * 2}")
    if cards != binding_count * 3:
        raise SystemExit(f"apkg cards {cards} != {binding_count * 3} (study front, study reverse, reference)")
    return notes, cards


def verify_pdf_pages(path: Path, expected: int) -> int:
    info = subprocess.run(["pdfinfo", str(path)], check=True, capture_output=True, text=True)
    pages = 0
    for line in info.stdout.splitlines():
        if line.startswith("Pages:"):
            pages = int(line.split()[1])
    if pages != expected:
        raise SystemExit(f"{path.name}: {pages} pages, expected {expected}")
    return pages


def render_previews(duplex: Path, reference: Path, bindings: list[Binding], preview_dir: Path) -> list[Path]:
    preview_dir.mkdir(parents=True, exist_ok=True)

    def page_of(action_contains: str) -> int:
        for index, binding in enumerate(bindings, start=1):
            if action_contains in binding.action:
                return index
        raise SystemExit(f"no card matching {action_contains!r}")

    move = page_of("Move window to left monitor")
    notify = page_of("Dismiss, invoke, or focus last notification")
    jobs = [
        (duplex, move * 2 - 1, preview_dir / "3x5-front-move-window.png"),
        (duplex, move * 2, preview_dir / "3x5-back-move-window.png"),
        (reference, notify, preview_dir / "3x5-reference-notification.png"),
    ]
    written = []
    for pdf, page, dest in jobs:
        prefix = dest.with_suffix("")
        subprocess.run(
            ["pdftoppm", "-f", str(page), "-l", str(page), "-png", "-r", "160", str(pdf), str(prefix)],
            check=True,
        )
        produced = prefix.parent / f"{prefix.name}-{page}.png"
        produced.replace(dest)
        written.append(dest)
    return written


def edge_ink(path: Path, margin_px: int = 16) -> int:
    from PIL import Image

    image = Image.open(path).convert("RGB")
    width, height = image.size
    pixels = image.load()
    hits = 0
    for y in range(height):
        for x in range(width):
            if x >= margin_px and y >= margin_px and x < width - margin_px and y < height - margin_px:
                continue
            red, green, blue = pixels[x, y]
            if red < 250 or green < 250 or blue < 250:
                hits += 1
    return hits


def category_counts(bindings: list[Binding]) -> list[tuple[str, int]]:
    counts: dict[str, int] = defaultdict(int)
    for binding in bindings:
        counts[binding.category] += 1
    return [(name, counts[name]) for name in CATEGORY_ORDER if counts[name]]


def default_paths(live: bool) -> tuple[Path, Path | None]:
    if live:
        directory = Path("/usr/share/omarchy/default/hypr/bindings")
        user = Path.home() / ".config/hypr/bindings.lua"
        if not directory.is_dir():
            raise SystemExit(f"--live: {directory} is not on this machine. Use the snapshot in flashcards/source/.")
        return directory, user if user.exists() else None
    return SOURCE, SOURCE / "user-bindings.lua"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate Omarchy keybinding flash cards.")
    parser.add_argument("--bindings-dir", type=Path, help="Directory of default binding .lua files.")
    parser.add_argument("--user-bindings", type=Path, help="Personal bindings.lua (o.bind / o.rebind / hl.unbind).")
    parser.add_argument("--live", action="store_true", help="Read /usr/share/omarchy and ~/.config/hypr/bindings.lua.")
    parser.add_argument("--only-installed", action="store_true", help="Drop dictation and other command-gated binds whose program is not installed.")
    parser.add_argument("--no-preinstalled", action="store_true", help="Skip the preinstalled app and web-app block.")
    parser.add_argument("--no-4x6", action="store_true", help="Skip the 4x6 index-card PDFs.")
    parser.add_argument("--check", action="store_true", help="Parse and validate, and do not write decks.")
    parser.add_argument("--out", type=Path, default=ROOT, help="Directory for the CSV, apkg, and PDFs.")
    args = parser.parse_args(argv)

    if args.bindings_dir or args.user_bindings:
        bindings_dir = args.bindings_dir or SOURCE
        user_bindings = args.user_bindings
    else:
        bindings_dir, user_bindings = default_paths(args.live)
    options = Options(include_optional=not args.only_installed, no_preinstalled=args.no_preinstalled)
    try:
        recorder = load_all(bindings_dir, user_bindings, options)
    except LuaError as exc:
        raise SystemExit(f"Could not parse bindings: {exc}") from exc
    bindings = sort_bindings(recorder.bindings)
    assign_ordinals(bindings)
    disambiguate(bindings)
    if not args.only_installed and not args.no_preinstalled and bindings_dir == SOURCE:
        validate(bindings, recorder.per_file)

    counts = category_counts(bindings)
    print(f"Bindings: {len(bindings)}")
    for name, count in counts:
        print(f"  {name}: {count}")
    if recorder.skipped:
        print("Skipped:")
        for raw, action, why in recorder.skipped:
            print(f"  {raw} ({action}): {why}")
    else:
        print("Skipped active bindings: none")
    if user_bindings and user_bindings.exists():
        examples = commented_examples(user_bindings)
        if examples:
            print("Commented examples in the user file (not bindings):")
            for example in examples:
                print(f"  {example}")

    if args.check:
        print(f"Check passed for {len(bindings)} bindings.")
        return 0

    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    csv_path = out / "omarchy-keybindings.csv"
    apkg_path = out / "omarchy-keybindings.apkg"
    write_csv(bindings, csv_path)
    write_apkg(bindings, apkg_path)
    notes, cards = verify_apkg(apkg_path, len(bindings))
    print(f"Anki package: {notes} notes, {cards} cards ({apkg_path.name})")

    total = len(bindings)
    duplex_pages = []
    reference_pages = []
    for index, binding in enumerate(bindings, start=1):
        duplex_pages.append(study_front(binding, index, total))
        duplex_pages.append(study_back(binding, index, total))
        reference_pages.append(reference_face(binding, index, total))

    outputs = {
        "3x5": (
            out / "omarchy-keybindings-3x5-duplex.pdf",
            out / "omarchy-keybindings-3x5-reference.pdf",
        )
    }
    if not args.no_4x6:
        outputs["4x6"] = (
            out / "omarchy-keybindings-4x6-duplex.pdf",
            out / "omarchy-keybindings-4x6-reference.pdf",
        )
    for size, (duplex_path, reference_path) in outputs.items():
        print(f"Writing {size} PDFs...")
        write_pdf(duplex_pages, duplex_path, size)
        write_pdf(reference_pages, reference_path, size)
        verify_pdf_pages(duplex_path, total * 2)
        verify_pdf_pages(reference_path, total)
        print(f"  {duplex_path.name}: {total * 2} pages")
        print(f"  {reference_path.name}: {total} pages")

    if "3x5" in outputs:
        previews = render_previews(outputs["3x5"][0], outputs["3x5"][1], bindings, out / "previews")
        for preview in previews:
            ink = edge_ink(preview)
            print(f"Preview {preview.relative_to(REPO)} edge ink {ink}")
            if ink:
                raise SystemExit(f"{preview.name} has ink inside the outer margin ({ink} pixels)")
    print("Wrote", csv_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
