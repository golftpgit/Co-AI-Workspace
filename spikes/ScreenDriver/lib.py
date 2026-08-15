# -*- coding: utf-8 -*-
"""Helpers this round added: focus-then-type, and pasting Thai."""
import ax, time, subprocess, os

def dump(width=110):
    return ax.dump(width).split("\n")

def index_of(line):
    """The element number the dump printed, not the list position.

    They differ: `ax.dump` prefixes every line with its own counter and the
    output can carry leading noise, so `enumerate` is off by however much. This
    cost one round a press on the wrong element.
    """
    try:
        return int(line.split(":", 1)[0])
    except ValueError:
        return None

def find(pred, lines=None):
    lines = lines if lines is not None else dump()
    return [index_of(l) for l in lines if pred(l) and index_of(l)]

def focus(index):
    ax.run('set focused of item %d of els to true\nreturn "ok"' % index, quiet=True)
    time.sleep(0.35)

def typ(text):
    ax.run('tell application "System Events" to keystroke "%s"'
           % text.replace('\\', '\\\\').replace('"', '\\"'))
    time.sleep(0.35)

def type_into(index, text, clear=True):
    focus(index)
    if clear:
        ax.run('tell application "System Events" to keystroke "a" using command down')
        time.sleep(0.2)
    typ(text)

def paste_into(index, text):
    """Thai cannot be produced by `keystroke`; the clipboard can carry it."""
    path = "/tmp/coai_paste.txt"
    with open(path, "w") as f:
        f.write(text)
    subprocess.run(["osascript", "-e",
                    'set the clipboard to (read POSIX file "%s" as «class utf8»)' % path])
    focus(index)
    ax.run('tell application "System Events" to keystroke "a" using command down')
    time.sleep(0.2)
    ax.run('tell application "System Events" to keystroke "v" using command down')
    time.sleep(0.6)

def press(index):
    ax.at(index, 'press')
    time.sleep(1.2)

def alive():
    return ax.run('return (count of windows)', quiet=True)
