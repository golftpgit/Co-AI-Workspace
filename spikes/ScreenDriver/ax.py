# -*- coding: utf-8 -*-
"""Drive Co-AI Workspace through the accessibility API, via System Events.

System Events already has Accessibility permission on this machine; a fresh
binary of our own would need its own grant, which needs a human in System
Settings. So everything goes through osascript.
"""
import subprocess
import sys

APP = "Co-AI Workspace"

HEADER = u'''
tell application "System Events"
  tell process "%s"
    set frontmost to true
    with timeout of 180 seconds
      set els to entire contents of (first window whose name is "Co-AI Workspace")
    end timeout
''' % APP

FOOTER = u'''
  end tell
end tell
'''


def run(body, quiet=False):
    script = HEADER + body + FOOTER
    proc = subprocess.run(["osascript", "-"], input=script.encode("utf-8"),
                          capture_output=True)
    out = proc.stdout.decode("utf-8", "replace").strip()
    err = proc.stderr.decode("utf-8", "replace").strip()
    if err and not quiet:
        print("AXERR:", err, file=sys.stderr)
    return out


def dump(maxlen=90):
    body = u'''
    set acc to ""
    set n to 0
    repeat with e in els
      set n to n + 1
      set txt to ""
      try
        set txt to (role of e as text)
      end try
      try
        if name of e is not missing value then set txt to txt & " N=" & (name of e as text)
      end try
      try
        if description of e is not missing value then set txt to txt & " D=" & (description of e as text)
      end try
      try
        if value of e is not missing value then set txt to txt & " V=" & (value of e as text)
      end try
      set acc to acc & n & ": " & txt & linefeed
    end repeat
    return acc
    '''
    text = run(body)
    lines = []
    for line in text.split("\n"):
        lines.append(line[:maxlen])
    return "\n".join(lines)


def _finder(match, role=None, occurrence=1):
    """AppleScript that leaves `target` set to the wanted element."""
    role_test = u'(role of e as text) is "%s"' % role if role else u'true'
    return u'''
    set target to missing value
    set hits to 0
    repeat with e in els
      set txt to ""
      try
        if name of e is not missing value then set txt to txt & (name of e as text)
      end try
      try
        if description of e is not missing value then set txt to txt & "|" & (description of e as text)
      end try
      try
        if value of e is not missing value then set txt to txt & "|" & (value of e as text)
      end try
      if txt contains "%s" and %s then
        set hits to hits + 1
        if hits is %d then
          set target to e
          exit repeat
        end if
      end if
    end repeat
    ''' % (match, role_test, occurrence)


def click(match, role=None, occurrence=1):
    body = _finder(match, role, occurrence) + u'''
    if target is missing value then return "NOTFOUND"
    click target
    return "OK"
    '''
    return run(body)


def press(match, role=None, occurrence=1):
    body = _finder(match, role, occurrence) + u'''
    if target is missing value then return "NOTFOUND"
    perform action "AXPress" of target
    return "OK"
    '''
    return run(body)


def settext(match, text, role="AXTextField", occurrence=1):
    body = _finder(match, role, occurrence) + u'''
    if target is missing value then return "NOTFOUND"
    set focused of target to true
    set value of target to "%s"
    return "OK"
    ''' % text.replace('"', '\\"')
    return run(body)


def typeinto(match, text, role="AXTextField", occurrence=1):
    """Click the field, then type — for SwiftUI fields that ignore setValue."""
    body = _finder(match, role, occurrence) + u'''
    if target is missing value then return "NOTFOUND"
    click target
    delay 0.2
    keystroke "a" using command down
    keystroke "%s"
    return "OK"
    ''' % text.replace('"', '\\"').replace("\\", "\\\\")
    return run(body)


def exists(match):
    body = _finder(match) + u'''
    if target is missing value then return "NO"
    return "YES"
    '''
    return run(body) == "YES"


def texts(contains):
    body = u'''
    set acc to ""
    repeat with e in els
      try
        if (role of e as text) is "AXStaticText" then
          if name of e is not missing value then
            if (name of e as text) contains "%s" then
              set acc to acc & (name of e as text) & linefeed
            end if
          end if
        end if
      end try
    end repeat
    return acc
    ''' % contains
    return run(body)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "dump":
        width = int(sys.argv[2]) if len(sys.argv) > 2 else 90
        print(dump(width))


# ── index-based addressing, for the many unnamed SwiftUI fields ──

def at(index, action="click"):
    body = u'''
    set target to item %d of els
    %s
    return "OK"
    ''' % (index, {"click": "click target",
                   "press": 'perform action "AXPress" of target'}[action])
    return run(body)


def set_at(index, text):
    body = u'''
    set target to item %d of els
    set focused of target to true
    delay 0.15
    set value of target to "%s"
    delay 0.15
    return (value of target as text)
    ''' % (index, text.replace('"', '\\"'))
    return run(body)


def type_at(index, text):
    body = u'''
    set target to item %d of els
    click target
    delay 0.25
    tell application "System Events" to keystroke "a" using command down
    tell application "System Events" to keystroke "%s"
    delay 0.25
    return "OK"
    ''' % (index, text.replace('\\', '\\\\').replace('"', '\\"'))
    return run(body)


def choose(index, option):
    """Pick an option from a pop-up button at `index`."""
    body = u'''
    set target to item %d of els
    perform action "AXPress" of target
    delay 0.6
    return "OPENED"
    ''' % index
    opened = run(body)
    if opened != "OPENED":
        return opened
    pick = u'''
    set found to "NOTFOUND"
    repeat with e in els
      try
        if (role of e as text) is "AXMenuItem" then
          if (title of e as text) contains "%s" then
            perform action "AXPress" of e
            set found to "OK"
            exit repeat
          end if
        end if
      end try
    end repeat
    return found
    ''' % option
    return run(pick)


def value_at(index):
    return run(u'''
    set target to item %d of els
    try
      return (value of target as text)
    end try
    return ""
    ''' % index)
