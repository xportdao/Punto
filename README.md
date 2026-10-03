# Punto for macOS

[Русская версия](README.ru.md)

Punto is a small menu-bar utility for macOS that fixes words typed in the wrong
keyboard layout, Russian instead of English or the other way round. It rewrites the
word you have just typed and switches to the right layout. It also offers voice
dictation into the focused text field of any app, tuned for Russian speech with
English terms that should stay in Latin script.

Examples:

- `ghbdtn ` → `привет `
- `руддщ ` → `hello `
- `ghbdtn` + Shift+6 on US International + Apple Russian layouts → `привет,`

Layout correction runs entirely on the Mac. Dictation uses Apple's Speech
framework; whether recognition runs on device depends on the language models
installed in macOS.

## Requirements

- macOS 13 or later, Apple Silicon (the build script targets `arm64`)
- Xcode Command Line Tools with Swift 5.10 or later
- Accessibility permission for layout correction; microphone and speech
  recognition permissions for dictation

## Build and run

```sh
./scripts/build-app.sh
open dist/Punto.app
```

To install into `/Applications` and restart a running copy:

```sh
./scripts/install-app.sh
```

If `swift build` is broken, for example after a partial Command Line Tools update,
the build script falls back to calling `swiftc` directly with the newest SDK the
installed compiler accepts. Set `PUNTO_SDK` to choose an SDK explicitly.

A deterministic self-test covers layout mapping, mixed-language selection,
punctuation, shortcuts and the dictation state machine:

```sh
.build/release/Punto --self-test
```

If XCTest is available in your toolchain, the XCTest suite runs with
`swift test --disable-sandbox`.

On first launch macOS asks for **System Settings → Privacy & Security →
Accessibility**. Once granted, the «P» icon in the menu bar becomes active. The
menu lets you pause correction, pick the dictation language and shortcut, and open
the relevant privacy settings.

## How layout correction works

1. Punto remembers the current word as a sequence of physical keystrokes, the key
   plus Shift and Caps Lock.
2. Both readings of the word are rendered through the real keyboard layouts with
   `UCKeyTranslate`: the active layout and the enabled layout of the other
   language. Any pair works, including US International with dead keys and Apple's
   «Russian» layout, where punctuation sits on the digit row.
3. The macOS spell checker compares the typed word with the alternative.
4. A word is replaced only when the typed word is unknown and the alternative is a
   known word. URLs, email addresses, paths, words with digits and input with
   Command, Control or Option are left alone.

Correction happens on Space, Return or Tab. If the key after a word types
punctuation in the target layout and no letter in the current one, the word is
fixed as soon as that key is pressed. The `.` and `,` keys are letters in the
Russian layout, so such words are fixed on Space and the typed mark is kept. The
mode is deliberately conservative: unfamiliar names and technical terms are better
left untouched.

Check a word against your own layouts without typing it:

```sh
/Applications/Punto.app/Contents/MacOS/Punto --check-word 'ghbdtn^'
```

### Grey menu-bar icon, no correction

A grey icon and the menu item «Нужен доступ к управлению компьютером» mean that
`AXIsProcessTrusted()` returned `false` and the keyboard tap did not start.

An ad-hoc signature without an explicit requirement gets a designated requirement
of the form `cdhash H"…"`, which changes on every build. macOS stores that
requirement with the Accessibility grant, so each rebuild silently lost the
permission. `scripts/build-app.sh` signs with `identifier "local.punto.autolayout"`
instead, which survives rebuilds. If the permission still belongs to an old build:

```sh
tccutil reset Accessibility local.punto.autolayout
open /Applications/Punto.app
```

## Voice dictation

1. Put the cursor into a text field.
2. Press **Option–Space** and speak. The menu-bar icon turns red.
3. Press **Space** to finish. Punto normalizes spacing, punctuation and
   capitalization and pastes the result into the same field. The finishing space
   is not inserted.

Pressing the shortcut again also finishes dictation. The shortcut can be changed in
the **Сочетание клавиш** menu. Shortcuts already taken in System Settings →
Keyboard → Keyboard Shortcuts are disabled there, because Punto's tap sees them
before the system does. Control–Fn and Fn–Space only work with Apple keyboards:
most third-party keyboards, such as Logitech MX Keys, handle Fn in firmware and
never send it to the Mac.

The result is pasted through the system paste action so that Electron and Chromium
editors accept it. The previous clipboard content is restored afterwards unless you
copy something new in the meantime.

### Russian with English terms

In the `Авто: Русский + English` mode Punto runs the `ru-RU` and `en-US` system
models at the same time. macOS 26 allows only one active recognition task per
process, so the second language runs in a helper process, `Punto
--recognizer-helper`, which receives audio over a pipe.

Punto never translates. It picks a base language for the whole utterance and then
lets words from the other model in only locally: a word replaces the overlapping
words of the base language, or fills a pause, when it looks like a term and the
model is confident enough. A term is a known name such as `Claude`, `GitHub`,
`API`, `Docker` or `Slack`, an all-caps abbreviation, CamelCase, a word with
digits, or a base-language word missing from the dictionary. Add your own terms to
`~/Library/Application Support/Punto/terms.txt`, one per line.

### Punctuation

Apple's Russian models return no punctuation at all, neither `SFSpeechRecognizer`
nor the macOS 26 `DictationTranscriber`, while the English ones do. Punto keeps
punctuation the recognizer already produced and adds its own to unpunctuated text:

- a pause of about 0.55 s becomes a comma, about 1.1 s ends the sentence;
- commas after an opening greeting and before conjunctions and subordinate words
  such as «но», «а», «чтобы», «если», «когда», «потому что», «что», «который»;
- a question mark for a question word at the start or after a greeting, the
  particle «ли», or «ты»/«вы» with a predicate such as «слышишь» or «готовы» at
  the end;
- spoken marks: «запятая», «вопросительный знак», «восклицательный знак»,
  «двоеточие», «точка с запятой», «многоточие», and «точка» at the end of a
  phrase or before a pause.

Punto does not analyse intonation. A question without any of these cues gets a
period, so say «вопросительный знак». Fluent speech leaves almost no gaps between
sentences, so long dictation needs a pause of about a second or the word «точка»
to split sentences.

## Diagnostics

Every shortcut activation is written to the unified log:

```sh
log show --last 5m --predicate 'subsystem == "local.punto.autolayout"' --style compact
```

Send a synthetic shortcut to the running app. `open` is needed so the command runs
with Punto.app's Accessibility permission:

```sh
open -n -a /Applications/Punto.app --args --post-test-shortcut option-space
```

Punto keeps the last dictation in
`~/Library/Application Support/Punto/last-dictation.caf`. Run the same recognition
pipeline on any audio file and see what each model returned and what Punto chose:

```sh
open -n -a /Applications/Punto.app --args \
  --transcribe-file ~/Library/Application\ Support/Punto/last-dictation.caf \
  --out /tmp/punto-report.txt
cat /tmp/punto-report.txt
```

`--fast` feeds audio faster than real time, `--only ru-RU` or `--only en-US` keeps
a single model.

## Limitations

- Only layouts whose primary language is English or Russian are used, the first
  enabled layout of each language.
- Secure input fields, such as password fields, block global keyboard taps.
- Term spelling and language switching are limited to what the system speech
  models return. Punto does not invent or translate words.
- The menu and messages are in Russian.
- For distribution beyond your own Mac the app should be signed with a Developer ID
  and notarized.

## Credits

The «P» sign in `Resources/parking.svg`, used for the menu-bar icon and the app
icon, is the «parking» icon from [Font Awesome Free 5](https://fontawesome.com) by
Fonticons, Inc., licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) and obtained via
SVG Repo. The app icon recolors it as a white sign on a blue tile.
