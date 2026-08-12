#!/usr/bin/env python3
"""Accessibility rules that can be checked mechanically (ARCHITECTURE §14.4, P8.7).

v1 shipped a frontend with no `aria-*` at all and then had to go back through
16 buttons in 8 files. The lesson written into the plan is that accessibility
is a requirement from the start rather than a later pass — and a requirement
nothing enforces is a preference. So these two rules run in `scripts/check.sh`
alongside the structural ones, and they fail the build:

  1. **An icon-only button must say what it does.** A button whose entire label
     is an SF Symbol is, to VoiceOver, a button called "play.fill". `Label(…)`
     and any button with text are fine — they already say it.

  2. **An action must be reachable without a mouse.** `.onTapGesture` on a row
     is invisible to the keyboard and to VoiceOver: there is no focusable
     control there, so the action does not exist for anyone not pointing at it.
     A `Button` with `.buttonStyle(.plain)` looks identical and is reachable.

  3. **A context menu needs a second door.** Right-click is a mouse, and on a
     Mac keyboard there is often no menu key at all. `.accessibilityAction`
     puts the same action in VoiceOver's rotor without changing the design,
     which is what makes it a fix somebody will actually apply rather than
     argue with.

Both rules are approximations over source text, which is the trade: they are
cheap enough to run on every build. A false positive is fixed by adding a
label, which is what you wanted anyway.

Usage: accessibility-audit.py <directory>...
"""

import re
import sys
from pathlib import Path

# How far after a `Button {` to look for the end of its label and for a label.
WINDOW = 10

ALLOWED_TAP = re.compile(r"//\s*a11y-ok:")


def button_blocks(lines):
    """Yield (line_number, block_text) for each Button and its nearby modifiers."""
    for index, line in enumerate(lines):
        if re.search(r"\bButton\b", line) and "//" not in line.split("Button")[0]:
            yield index + 1, "\n".join(lines[index:index + WINDOW])


def icon_only_without_label(path, lines):
    problems = []
    for number, block in button_blocks(lines):
        if "Image(systemName:" not in block:
            continue
        # Where the button's own text would be. Cut the block at the first
        # line that closes the label closure at column 0-ish, to avoid reading
        # the *next* view's Text as this button's.
        head = block.split("\n")
        cut = []
        depth = 0
        for line in head:
            cut.append(line)
            depth += line.count("{") - line.count("}")
            if depth <= 0 and len(cut) > 1:
                break
        text = "\n".join(cut)
        # A button that shows words is already announced as those words.
        if re.search(r"\bText\(|\bLabel\(", text):
            continue
        # The modifier usually sits just after the closing brace, so look at a
        # couple of lines past the block as well.
        after = "\n".join(head[len(cut):len(cut) + 4])
        if "accessibilityLabel" in text or "accessibilityLabel" in after:
            continue
        problems.append(f"{path}:{number}: icon-only button with no accessibilityLabel")
    return problems


def mouse_only_actions(path, lines):
    problems = []
    for index, line in enumerate(lines):
        if ".onTapGesture" not in line:
            continue
        # An explicit, justified exception — written next to the line so the
        # reason travels with it.
        context = "\n".join(lines[max(0, index - 2):index + 1])
        if ALLOWED_TAP.search(context):
            continue
        problems.append(f"{path}:{index + 1}: .onTapGesture — a mouse-only action "
                        "(use a Button with .buttonStyle(.plain), or mark "
                        "`// a11y-ok: <reason>`)")
    return problems


def unmirrored_context_menus(path, lines):
    """A `.contextMenu` with no `.accessibilityAction` following it."""
    problems = []
    for index, line in enumerate(lines):
        if ".contextMenu" not in line:
            continue
        # The menu's own block, then the modifiers after it. A generous window:
        # the mirror belongs directly after the menu, but the menu itself can
        # be several items long.
        following = "\n".join(lines[index:index + 14])
        if "accessibilityAction" in following:
            continue
        if ALLOWED_TAP.search("\n".join(lines[max(0, index - 2):index + 1])):
            continue
        problems.append(f"{path}:{index + 1}: .contextMenu with no .accessibilityAction "
                        "— right-click is a mouse (mirror it, or mark "
                        "`// a11y-ok: <reason>`)")
    return problems


def main(directories):
    problems = []
    for directory in directories:
        for path in sorted(Path(directory).rglob("*.swift")):
            lines = path.read_text(encoding="utf-8").splitlines()
            problems += icon_only_without_label(path, lines)
            problems += mouse_only_actions(path, lines)
            problems += unmirrored_context_menus(path, lines)
    for problem in problems:
        print(f"   {problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["Sources"]))
