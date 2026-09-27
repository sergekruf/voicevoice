# VoiceVoice

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/sergekruf/voicevoice)](https://github.com/sergekruf/voicevoice/releases/latest)
[![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange?logo=apple)](#requirements)
[![Downloads](https://img.shields.io/github/downloads/sergekruf/voicevoice/total?label=downloads)](https://github.com/sergekruf/voicevoice/releases)

🇷🇺 [Читать на русском](README.md)

**Voice dictation for macOS with local speech recognition.** Hold `Fn`, talk, release — the text appears in any active input field. Recognition runs entirely on your machine via the Apple Neural Engine — not a single phrase leaves your computer.

Landing: [voicevoice.vectrolab.ru](https://voicevoice.vectrolab.ru) · Pre-built `.dmg` available

## Features

- **Hotkey-driven dictation** — `Fn` (default), right `⌥ Option`, or `Caps Lock`. Hold → talk → release → text in your field.
- **Two local engines**:
  - [**GigaAM-v3**](https://github.com/salute-developers/GigaAM) (Sber) — best quality for Russian: punctuation and digits out of the box. Beam-search decoding with hotword biasing from your dictionary (Claude, API…). ~400 MB model.
  - [**Parakeet TDT v3**](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) via [FluidAudio](https://github.com/FluidInference/FluidAudio) — fast, 25 European languages. ~600 MB model.

  The selected engine's model downloads on first launch; inference runs on the Apple Neural Engine, 0.1–0.5 s per phrase. The app itself is ~14 MB and uses ~80 MB of RAM.
- **Long dictations without broken sentences** — audio is cut at pauses and chunk seams are re-checked with context, so false periods, «?» and capitals mid-sentence are removed. Lost «?» is restored from grammar.
- **Adaptive dictionary** — for ~5 minutes after a successful paste, VoiceVoice watches the focused field. If you correct the recognized text, it remembers `wrong → right` pairs and auto-applies them on subsequent dictations.
- **Fuzzy matching** with configurable threshold — a `клод код → Claude Code` rule also fires on `клот кот`, `клоуд код`, etc. Ordinary Russian words are never fuzzy-replaced.
- **Dictionary audit** — on a schedule, finds rules that may damage text (ordinary-word replacements, duplicates) and suggests removing them.
- **Edit & Learn** for apps where Accessibility can't read field contents (Bitrix24, Max, Slack, Termius…) — one-click manual correction from the HUD.
- **Three-tier paste**: CGEvent ⌘V → AppleScript → AXUIElement direct write. Text reaches anywhere — Notes, Safari, Telegram, Termius, Slack, VS Code, Cursor, Claude Desktop, Max, Bitrix24…
- **TransientType marker** for clipboard managers (Maccy / Paste / PasteNow / Raycast) — our temporary clipboard writes don't pollute your history.
- **Number normalization** — «две тысячи пятьсот тридцать два» → `2532`, ordinals → «24-го», «три с половиной» → `3,5`.
- **Result HUD** + history of last 200 transcriptions + searchable dictionary.
- **Quiet mode** — hide all popups / toasts while keeping the recording indicator visible. Great for screencasts.
- **Privacy-by-default** — zero telemetry, zero cloud, sandbox-compatible, ad-hoc signed with a stable identity (TCC permissions survive rebuilds).

## Requirements

- macOS **14 Sonoma** or newer
- Apple Silicon (M1 / M2 / M3 / M4 / M5) — models run on the Neural Engine; there is no Intel build
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

Or via Xcode: `open Package.swift`, wait for FluidAudio + GRDB resolution, hit ▶︎ Run.

## First launch

1. Onboarding window appears. Grant:
   - **Microphone** — click "Request access".
   - **Accessibility** — needed to globally hear `Fn` and emulate `⌘V`. macOS opens System Settings → Privacy & Security → Accessibility; manually toggle VoiceVoice on.
2. **Disable system dictation:** System Settings → Keyboard → Dictation → off. Otherwise macOS's overlay intercepts `Fn` on top of ours.
3. On first launch the selected engine's model downloads (~400–600 MB). Switch engines in Settings: GigaAM for Russian, Parakeet for other languages. Progress shows in the menu bar.

## Usage

1. Put the cursor in any text field.
2. **Hold Fn** → the "Recording…" indicator appears.
3. Speak. No need to dictate punctuation — GigaAM places it on its own.
4. **Release Fn** → after ~0.5–1 s (on M4) the text appears in the field.
5. If something was misrecognized — the auto-dictionary picks up your manual fix if you correct it within 5 minutes. For apps without AX support — click "Edit & Learn" in the HUD.

## Where data lives

```
~/Library/Application Support/VoiceVoice/
├── data.db           # SQLite (GRDB): dictionary + history
└── models/GigaAM/    # GigaAM Core ML model; Parakeet lives in ~/Library/Application Support/FluidAudio
```

Wipe everything:
```bash
rm -rf "$HOME/Library/Application Support/VoiceVoice"
```

## Project layout

```
voicevoice/
├── Package.swift                 # SwiftPM manifest (FluidAudio, GRDB)
├── build-app.sh                  # build .app bundle from CLI
├── make-dmg.sh                   # build installer .dmg
├── setup-signing.sh              # create self-signed identity
└── Sources/VoiceVoice/
    ├── VoiceVoiceApp.swift       # @main, MenuBarExtra
    ├── Resources/                # Info.plist, entitlements, GigaAM word pieces
    ├── Models/                   # AppSettings, CorrectionEntry, TranscriptionRecord
    ├── Storage/                  # GRDB Database, CorrectionStore, HistoryStore
    ├── Services/
    │   ├── AudioRecorder.swift   # AVAudioEngine 16 kHz mono
    │   ├── GigaAMTranscriber.swift # GigaAM-v3 on Core ML (encoder on ANE)
    │   ├── RNNTBeamSearch.swift  # beam search + hotword biasing
    │   ├── ParakeetTranscriber.swift # Parakeet via FluidAudio
    │   ├── Transcriber.swift     # shared: pause-based chunking, joining, seams
    │   ├── PunctuationFixer.swift # clause merging, lost «?» restoration
    │   ├── HotkeyMonitor.swift   # глобальный CGEvent-tap
    │   ├── TextInserter.swift    # three-tier paste + TransientType marker
    │   ├── TextChangeWatcher.swift # auto-dictionary via AX polling + BFS
    │   ├── ClipboardSnapshot.swift # NSPasteboard snapshot / restore
    │   ├── NumberNormalizer.swift
    │   ├── Tokenizer.swift       # Unicode word/non-word tokens
    │   ├── DiffEngine.swift      # token-level LCS diff
    │   ├── CorrectionApplier.swift # apply dictionary (exact + fuzzy)
    │   ├── DictionaryAudit.swift # dictionary audit
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
- [**GigaAM-v3**](https://github.com/salute-developers/GigaAM) (converted to Core ML, encoder on ANE)
- [**FluidAudio**](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v3)
- [**GRDB**](https://github.com/groue/GRDB.swift) (SQLite wrapper)

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Code style: Swift API Design Guidelines.

## License

MIT — see [LICENSE](LICENSE). GigaAM and GRDB are MIT, FluidAudio is Apache 2.0, the Parakeet model is CC-BY-4.0.

---

Built at [VectroLab](https://vectrolab.ru) · Yekaterinburg
