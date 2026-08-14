# Text Shortcuts

A self-contained, system-wide text-expansion tool written in pure PowerShell — no
AutoHotkey or other software required. Type a short abbreviation and it **instantly**
expands into the full text, in **any** application (email, browser, Word, etc.).

## How it works

There is **no trigger character.** The moment you finish typing a defined
abbreviation, it is deleted and replaced with its expansion.

Examples (from the starter `shortcuts.json`):

| Type this | You get |
|-----------|---------|
| `mysig`  | your full email signature |
| `myem`   | `your email address` |
| `myco`   | `Integrated IT Solutions` |
| `thxx`   | `Thank you,` / `-Carl` |
| `ddate`  | today's date |
| `myack`  | an acknowledgement reply |

Matching is **word-boundary aware**: an abbreviation only fires when typed as its own
word, never as part of a longer word (e.g. `xmysig` does nothing).

## Choosing abbreviations (important)

Because there is no trigger character and expansion is instant, pick **distinctive
abbreviations you would never type as a normal word.** Good: `mysig`, `myem`, `ddate`.
Avoid real words like `now` or `date` on their own — they'd expand mid-sentence.
Also avoid making one abbreviation the start of another (e.g. don't use both `my`
and `myem`, or `my` would fire first).

## Start / stop

- **Start:** double-click **`Start-TextShortcuts.cmd`** (opens a window and runs).
  Or run `pwsh -File TextShortcuts.ps1` in a terminal.
- **Stop:** press **Ctrl+C** in that window, or just close it. The keyboard hook is
  released automatically.
- **See loaded shortcuts:** `pwsh -File TextShortcuts.ps1 -List`

## Add your own shortcuts

Edit **`shortcuts.json`**:

```json
{
  "instantExpand": true,
  "matchCase": false,
  "shortcuts": {
    "myshort": "The full text it expands to.",
    "multi":   "Line one\nLine two"
  }
}
```

- Use `\n` for a new line.
- Dynamic tokens usable inside any expansion: `{date}`, `{time}`, `{datetime}`,
  `{enter}` (line break), `{tab}`. You can also just use `\n` for a new line.
- `"instantExpand": false` switches to the safer mode where an abbreviation only
  expands after you press space / Enter / punctuation (that ending key is kept).
- `"matchCase": true` makes abbreviations case-sensitive (default is case-insensitive).
- Restart the tool after editing the file to load the changes.

## Run it automatically at login (optional)

Press **Win+R**, type `shell:startup`, and drop a shortcut to
`Start-TextShortcuts.cmd` into that folder. It will then start every time you log in.

## Notes / limitations

- Expansion is sent as simulated keystrokes, so it works wherever you can type.
- A global keyboard hook is a normal Windows mechanism, but some endpoint-security
  tools flag any app that installs one. If yours does, allow-list this script.
