# VoiceVoice

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/sergekruf/voicevoice)](https://github.com/sergekruf/voicevoice/releases/latest)
[![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange?logo=apple)](#requirements)
[![Downloads](https://img.shields.io/github/downloads/sergekruf/voicevoice/total?label=downloads)](https://github.com/sergekruf/voicevoice/releases)

🇷🇺 [Читать на русском](README.md)

**Voice dictation for macOS with local Whisper.** Hold `Fn`, talk, release — the text appears in any active input field. Recognition runs entirely on your machine via the Apple Neural Engine — not a single phrase leaves your computer.

Landing: [voicevoice.vectrolab.ru](https://voicevoice.vectrolab.ru) · Pre-built `.dmg` available

## Features

- **Hotkey-driven dictation** — `Fn` (default), right `⌥ Option`, or `Caps Lock`. Hold → talk → release → text in your field.
- **Local Whisper** (`large-v3-turbo`, 4-bit quantized, ~632 MB) via [WhisperKit](https://github.com/argmaxinc/WhisperKit). Inference on the Apple Neural Engine, ~10× faster than real-time on M4.
- **Adaptive dictionary** — for ~5 minutes after a successful paste, VoiceVoice watches the focused field. If you correct the recognized text, it remembers `wrong → right` pairs and auto-applies them on subsequent dictations.
- **Fuzzy matching** with configurable threshold — a `клод код → Claude Code` rule also fires on `клот кот`, `клоуд код`, etc.
- **Edit & Learn** for apps where Accessibility can't read field contents (Bitrix24, Max, Slack, Termius…) — one-click manual correction from the HUD.
- **Three-tier paste**: CGEvent ⌘V → AppleScript → AXUIElement direct write. Text reaches anywhere — Notes, Safari, Telegram, Termius, Slack, VS Code, Cursor, Claude Desktop, Max, Bitrix24…
- **TransientType marker** for clipboard managers (Maccy / Paste / PasteNow / Raycast) — our temporary clipboard writes don't pollute your history.
- **Number normalization** — `«один миллион четыреста двадцать пять»` → `1 425 689`, extra spaces and periods stripped.
- **Auto-emoji** (optional) — appends one contextual emoji on trigger words: «спасибо» → 🙏, «поздравляю» → 🎉, «хаха» → 😄, etc.
- **Result HUD** + history of last 200 transcriptions + searchable dictionary.
- **Quiet mode** — hide all popups / toasts while keeping the recording indicator visible. Great for screencasts.
- **Privacy-by-default** — zero telemetry, zero cloud, sandbox-compatible, ad-hoc signed with a stable identity (TCC permissions survive rebuilds).

## Requirements

- macOS **13 Ventura** or newer (14+ recommended)
- Apple Silicon (M1 / M2 / M3 / M4 / M5) — on Intel Macs Whisper falls back to CPU and runs 5–10× slower, making interactive dictation impractical
- Xcode 15+ (only if building from source)
- Microphone + Accessibility permissions (requested on first launch)

## Installation

### Pre-built .dmg

Easiest path — download from the landing: [voicevoice.vectrolab.ru](https://voicevoice.vectrolab.ru) or [latest GitHub release](https://github.com/sergekruf/voicevoice/releases/latest).

### Build from source

```bash
git clone https://github.com/sergekruf/voicevoice.git
cd voicevoice
./setup-signing.sh    # one-time: creates a stable self-signed identity so TCC permissions persist across rebuilds
./build-app.sh        # builds the SwiftPM target → .app bundle → signs
open build/VoiceVoice.app
```

Or via Xcode: `open Package.swift`, wait for WhisperKit + GRDB resolution, hit ▶︎ Run.

## First launch

1. Onboarding window appears. Grant:
   - **Microphone** — click "Request access".
   - **Accessibility** — needed to globally hear `Fn` and emulate `⌘V`. macOS opens System Settings → Privacy & Security → Accessibility; manually toggle VoiceVoice on.
2. **Disable system dictation:** System Settings → Keyboard → Dictation → off. Otherwise macOS's overlay intercepts `Fn` on top of ours.
3. On first launch WhisperKit downloads the `large-v3-turbo` model (~632 MB) to `~/Library/Application Support/VoiceVoice/models/`. Progress shows in the menu bar.

## Usage

1. Put the cursor in any text field.
2. **Hold Fn** → the "Recording…" indicator appears.
3. Speak. You can dictate punctuation explicitly («запятая», «точка», «вопросительный знак») — Whisper places them reasonably well on its own.
4. **Release Fn** → after ~0.5–1 s (on M4) the text appears in the field.
5. If something was misrecognized — the auto-dictionary picks up your manual fix if you correct it within 5 minutes. For apps without AX support — click "Edit & Learn" in the HUD.

## Where data lives

```
~/Library/Application Support/VoiceVoice/
├── data.db           # SQLite (GRDB): dictionary + history
└── models/           # WhisperKit CoreML models
```

Wipe everything:
```bash
rm -rf "$HOME/Library/Application Support/VoiceVoice"
```

## Project layout

```
voicevoice/
├── Package.swift                 # SwiftPM manifest (WhisperKit, GRDB)
├── build-app.sh                  # build .app bundle from CLI
├── make-dmg.sh                   # build installer .dmg
├── setup-signing.sh              # create self-signed identity
└── Sources/VoiceVoice/
    ├── VoiceVoiceApp.swift       # @main, MenuBarExtra
    ├── Resources/                # Info.plist, entitlements
    ├── Models/                   # AppSettings, CorrectionEntry, TranscriptionRecord
    ├── Storage/                  # GRDB Database, CorrectionStore, HistoryStore
    ├── Services/
    │   ├── AudioRecorder.swift   # AVAudioEngine 16 kHz mono
    │   ├── Transcriber.swift     # WhisperKit wrapper
    │   ├── HotkeyMonitor.swift   # global CGEvent tap
    │   ├── TextInserter.swift    # three-tier paste + TransientType marker
    │   ├── TextChangeWatcher.swift # auto-dictionary via AX polling + BFS
    │   ├── ClipboardSnapshot.swift # NSPasteboard snapshot / restore
    │   ├── NumberNormalizer.swift
    │   ├── EmojiEnhancer.swift   # auto-emoji
    │   ├── Tokenizer.swift       # Unicode word/non-word tokens
    │   ├── DiffEngine.swift      # token-level LCS diff
    │   ├── CorrectionApplier.swift # apply dictionary (exact + fuzzy)
    │   └── AppController.swift   # orchestrator
    └── Views/
        ├── SettingsView.swift    # settings + HelpHint (`?` tooltips)
        ├── ResultHUD.swift       # post-recognition HUD
        ├── EditAndLearnWindow.swift
        ├── MenuBarContent.swift
        ├── HistoryView.swift
        ├── DictionaryView.swift
        ├── OnboardingView.swift
        └── WindowOpener.swift
```

## Known limitations

- In apps with empty / incomplete AX trees (Bitrix24 as a CEF app without AX, Max on Qt) **auto-learn is unavailable** — there's nothing to poll. Paste via ⌘V still works, and the HUD shows an Edit & Learn button for manual corrections.
- On external USB keyboards, `Fn` sometimes doesn't generate a modifier event — switch to right `⌥ Option` or `Caps Lock` in settings.
- When macOS system dictation is active, its overlay intercepts `Fn` — disable it (see onboarding).

## Stack

- **Swift 6** / **SwiftUI** / **AppKit** (MenuBarExtra, NSPanel, AXUIElement)
- [**WhisperKit**](https://github.com/argmaxinc/WhisperKit) (CoreML + ANE)
- [**GRDB**](https://github.com/groue/GRDB.swift) (SQLite wrapper)

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Code style: Swift API Design Guidelines.

## License

MIT — see [LICENSE](LICENSE). WhisperKit and GRDB are also MIT.

---

Built at [VectroLab](https://vectrolab.ru) · Yekaterinburg
