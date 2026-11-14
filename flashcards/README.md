# Omarchy keybinding flash cards

258 cards for the Hyprland bindings on this laptop. The snapshot is Omarchy 4.5.0-3 and Hyprland 0.56.2 (Lua config), copied on 2026-11-14 from:

- `/usr/share/omarchy/default/hypr/bindings/` (`applications`, `clipboard`, `dictation`, `input-method`, `jis`, `media`, `tiling`, `utilities`)
- `~/.config/hypr/bindings.lua`, stored here as [`source/user-bindings.lua`](source/user-bindings.lua)

The raw files are in [`source/`](source/). `generate.py` parses them, expands the numeric loops, and applies the personal file last. `o.rebind` replaces the chord. `hl.unbind` removes it. A new `o.bind` becomes a Personal card.

| Category | Cards |
| --- | ---: |
| Applications | 30 |
| Clipboard | 5 |
| Tiling | 109 |
| Utilities | 78 |
| Media | 30 |
| Dictation | 2 |
| Input method | 3 |
| JIS | 1 |
| **Total** | **258** |

Applications splits into Essential application bindings (7) and Preinstalled apps (23). Media splits into Volume, brightness, and hardware (16), Precise volume and brightness (4), and Media controls (10). Utilities includes 8 region-picker cards. Those groups are printed under the category and stored as Anki tags.

## Files

| File | What it is |
| --- | --- |
| [`omarchy-keybindings.apkg`](omarchy-keybindings.apkg) | Anki package with both decks |
| [`omarchy-keybindings-3x5-duplex.pdf`](omarchy-keybindings-3x5-duplex.pdf) | 3×5 study cards, front then back (516 pages) |
| [`omarchy-keybindings-3x5-reference.pdf`](omarchy-keybindings-3x5-reference.pdf) | 3×5 reference cards, one face (258 pages) |
| [`omarchy-keybindings-4x6-duplex.pdf`](omarchy-keybindings-4x6-duplex.pdf) | Same study set on 4×6 stock |
| [`omarchy-keybindings-4x6-reference.pdf`](omarchy-keybindings-4x6-reference.pdf) | Same reference set on 4×6 stock |
| [`omarchy-keybindings.csv`](omarchy-keybindings.csv) | `keys`, `action`, `category`, plus group, detail, tags, and the raw chord |
| [`previews/`](previews/) | Three rasterized 3×5 pages |

You can print and import these without running the generator.

## Anki

Anki is installed by `post-install.sh`, or run `sudo pacman -S anki`. The package is `anki` in Arch extra. The script skips the install when `pacman -Q anki` already succeeds, and `--dry-run` only prints the command. It does not open Anki. After the package step it prints the path of `flashcards/*.apkg` so you can import it yourself.

In Anki: File → Import, and choose `omarchy-keybindings.apkg`. Two decks come in.

**Omarchy Keybindings** is the study deck. The front is the action and the category. The back is the key combo. Each note has a second card that goes the other way: the keys are on the front, the action is on the back. That is 516 study cards (258 notes × 2).

**Omarchy Keybindings — Reference** is one card per binding. The key combo, the action, the category, and a short detail line are all on the front. The back repeats that same face, so flipping the card is not a second question.

Tags follow the category (`applications`, `clipboard`, `tiling`, `utilities`, `media`, `dictation`, `input-method`, `jis`) plus extras: `personal`, `preinstalled`, `essential`, `jis`, `conditional-dictation`, `conditional-lazydocker`, `region-picker`, `hardware-switch`, `apple`, `mouse`, `repeats`, `lock-screen`, and the media subgroups.

GUIDs are the chord plus that chord's order when one chord does two things (Alt+Tab both focuses the next window and raises it). They do not include the action text. Importing a regenerated package updates the existing notes instead of adding duplicates. Leave Anki's import option on updating notes that share a GUID.

## Printing

The PDF page **is** the card. There are no crop marks and no cover sheet.

### 3×5 duplex (study)

1. Paper size **5 in × 3 in**. That is a 3×5 index card in landscape. If the dialog lists the size as "3 x 5 in", pick it and set orientation to landscape. The page size in the file is already 5 in wide by 3 in tall.
2. Scale **100%** or **Actual size**. Do not use "fit to page", "shrink to fit", or a scale other than 100.
3. Margins **none**. The type already sits inside the edge. Turn off headers, footers, and any "print background" crop.
4. Duplex, **flip on the short edge**. Pages are ordered front, back, front, back. Short-edge flip keeps the answer upright when you turn the card left to right. Flip on the long edge and the back is upside down.

The card number is the same on both sides (`12 / 258`), so a jammed page is easy to pair.

### 3×5 reference

Same paper size, same 100% scale, same zero margins. Print single-sided. Each page already shows the keys and the action.

### 4×6

Same steps. Paper size **6 in × 4 in** (a 4×6 card in landscape). Use the `4x6` PDFs, not the 3×5 ones scaled up.

## Regenerate

```bash
python3 -m pip install -r flashcards/requirements.txt
python3 flashcards/generate.py
```

WeasyPrint needs Pango, cairo, and GDK-Pixbuf. On Arch those packages are `pango`, `cairo`, and `gdk-pixbuf2`. The preview check also uses `pdftoppm` from `poppler`.

The default read is `flashcards/source/`, with optional binds included (dictation, and Docker when the file gates it on `lazydocker`). After `omarchy update`, copy the new Lua files into `source/`, or point the script at the laptop:

```bash
python3 flashcards/generate.py --live
python3 flashcards/generate.py --live --only-installed
```

`--live` reads `/usr/share/omarchy/default/hypr/bindings` and `~/.config/hypr/bindings.lua`. `--only-installed` drops dictation unless `omarchy-default-dictation` prints a backend, and drops a command-gated bind such as Docker unless that program is on `PATH`. `--no-preinstalled` skips the preinstalled app and web-app block, the same switch as `omarchy_preinstalled_bindings = false`. `--check` parses and checks the count without writing files.

If a future Omarchy release uses Lua syntax this parser does not know, the script stops with a file and line instead of dropping that binding.

## What each card is

Personal overrides, applied on top of the defaults:

- `SUPER + SHIFT + ALT + A` is **Grok Bot** (`grok-bot`). It replaces the Grok web app.
- `SUPER + SHIFT + A` is the **Grok** web app (`https://grok.com`). It replaces ChatGPT.

Included, and marked on the card, because the file only binds them conditionally:

- **Dictation** (`ALT + Space`, and `ALT + Right Alt` push-to-talk) only while a dictation backend is installed. Tag `conditional-dictation`.
- **Docker** (`SUPER + SHIFT + D`) only while `lazydocker` is on `PATH`. Tag `conditional-lazydocker`.

**JIS** is one card: `CTRL + SHIFT + ;` zooms in, because on a Japanese layout `+` is Shift+semicolon. Tag `jis`. It does nothing useful on this US keyboard. It is here so the file is complete.

**Region picker** is eight keys (`Enter`, `Ctrl+Enter`, `Tab`, `Ctrl+Tab`, and the arrows) that Hyprland enables only while the screenshot region selector is open. The upstream file gives them no menu description, on purpose. The card title is what `omarchy-capture-region` does with that key. Tag `region-picker`.

**Apple SMC lid** open and close are included and tagged `apple`. This Dell does not send that switch. The title says "(Apple SMC)" so they are not the same card as the laptop lid.

Two study fronts that shared a name but not a command are labeled: Hey **Calendar (web app)** versus the bar **Calendar (clock panel)**.

No active binding was dropped.

These commented lines in `user-bindings.lua` are examples, not bindings, so they are not cards:

- `o.bind("SUPER + SHIFT + R", ...)` SSH
- `o.rebind("SUPER + SHIFT + F", ...)` Flea
- `hl.unbind("SUPER + SHIFT + B")`
- `o.bind("SUPER + H", ...)` voxtype
- `o.bind("SUPER + PERIOD", ...)` emojis

Mouse chords stay. Drag with Super moves or resizes a window. The wheel changes workspace or the window inside a group. Those are different gestures from the keyboard chords that do something similar, so each one is a card. A binding marked `repeating` in the Lua file is still one card. The detail line says it repeats while held.

`ALT + Tab` and `ALT + Shift + Tab` are each bound twice in `tiling.lua`, once to move focus and once to restack the window. Both actions are cards. The GUID uses the chord plus the order of those two actions, so a later edit of the description updates the note.

## Keycaps

The caps are HTML and CSS: a rounded rectangle, Super in cyan, the other keys in slate, labels in JetBrains Mono, titles in Liberation Sans. That is the same visual language as [maeck70/Omarchy-LazyVIM-CheatSheets](https://github.com/maeck70/Omarchy-LazyVIM-CheatSheets), which is the cheatsheet these cards are meant to sit next to.

That repository has no license (GitHub reports `license: null`, and there is no `LICENSE` file). Its SVG, PDF, and Python were not copied. Print cards use the light palette (white stock, blue Super cap) so a 3×5 card does not flood the page with ink. Anki uses the dark palette from the same cheatsheet.

Binding text comes from Omarchy (`omacom/omarchy`) as installed on this machine, plus the personal overrides in `source/user-bindings.lua`.
