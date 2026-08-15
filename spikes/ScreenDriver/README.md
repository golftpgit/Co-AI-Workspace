# Driving the built app by hand, repeatably

Every round of this project that drove the real screen found bugs the test suite
could not see, and every round rebuilt the driver from scratch first. This is
that driver, kept.

```python
import ax
ax.click(u'โต๊ะทำงาน', role='AXRadioButton')     # the four areas
ax.press(u'สลับพื้นที่ทำงานระหว่าง', role='AXMenuButton')
print(ax.dump(90))                                # the whole window, numbered
ax.at(410, 'press')                               # press element 410
ax.texts(u'KMO')                                  # every static text containing this
```

It talks to the app through System Events, which already holds the Accessibility
grant on this machine. A binary of our own would need its own grant, and that
needs a person in System Settings.

## What it cost to learn

- **Writing `AXValue` on a SwiftUI `TextField` does not reach the view's state.**
  The field displays the text, the "add" button stays disabled, and pressing it
  does nothing — which reads exactly like an app bug and is not one. Focus the
  field and use `keystroke` instead, then check `enabled of` the button before
  believing anything.
- **`set focused of <element> to true` is how you focus a field. Clicking is
  not.** `ax.type_at` clicks first, and on most of this app's `TextField`s the
  click lands without giving the field keyboard focus, so the text goes to
  whatever was focused before — usually the field above, whose contents it
  then replaces. This looked for three rounds like "the driver cannot type into
  SwiftUI", and it is not that. (2026-08-15)

      ax.run('set focused of item 48 of els to true')
      ax.run('tell application "System Events" to keystroke "123456789, 987654321"')

  Tab and Shift-Tab also work and are useful for walking a form, but the index
  after a Tab is a guess — a field that appears or disappears as you type (a
  validation line, a "remove" button) moves the tab order under you.
- **The keyboard layout decides what `keystroke` produces.** With Thai selected,
  every ASCII character arrives as `ฟ`. Switch first and switch back afterwards
  — it is the user's machine:

      osascript -e 'tell application "System Events" to keystroke space using {control down}'
      defaults read com.apple.HIToolbox AppleSelectedInputSources | grep "KeyboardLayout Name"

  `key code 49 using control down` does **not** switch it; `keystroke space
  using {control down}` does. Thai text still cannot be typed this way — for
  Thai input, drive a path that does not need typing.
- **`System Events` cannot read a SwiftUI button's name.** Every `AXButton` in
  this app answers with an empty `AXTitle` *and* an empty `AXDescription`,
  whether or not it has a label — SwiftUI hands the name over as
  `AXAttributedDescription`, which System Events cannot coerce to text. Reading
  the blank and concluding "this button is unlabelled" is a trap: it cost one
  round a self-inflicted regression (U31-1, 2026-08-15) where the "fix" removed
  the row's `AXPress` entirely. Check `name of actions of e` to find out whether
  a control still works; use `accessibility-audit.py` to find out whether it has
  a label. Neither question is answered by the dump.

- **Element indices move** whenever the view adds a summary line. Re-`dump()`
  before each action rather than reusing an index from three steps ago.
- **A control scrolled out of view may not respond.** Set the scroll bar's value
  to `1.0` first, then press.
- **Target the window by name.** A Keychain prompt arrives as another window and
  becomes window 1, at which point everything addressed by index is wrong.

- **`osascript` can go quiet after a rebuild.** A relaunched app sometimes comes
  up with zero windows and System Events answers "Invalid index" or refuses
  assistive access. `open` the app a second time; the window comes back. Check
  `count of windows` before concluding the app is broken.
- **A crash inside SwiftUI's update pass leaves no window and no log line.**
  `pgrep` shows the sidecar surviving and the app gone. The crash report is in
  `~/Library/Logs/DiagnosticReports/CoAIWorkspace-*.ips`; read the faulting
  thread's frames from the JSON second line, not the first.
