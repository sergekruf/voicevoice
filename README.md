# VoiceVoice

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/sergekruff/voicevoice)](https://github.com/sergekruff/voicevoice/releases/latest)
[![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange?logo=apple)](#требования)
[![Downloads](https://img.shields.io/github/downloads/sergekruff/voicevoice/total?label=downloads)](https://github.com/sergekruff/voicevoice/releases)

🇬🇧 [Read in English](README.en.md)

**Голосовая диктовка для macOS с локальным Whisper.** Зажал `Fn`, наговорил, отпустил — и текст появляется в любом активном поле ввода. Распознавание идёт целиком на твоей машине через Apple Neural Engine — ни одна фраза не уходит в облако.

Лендинг: [voicevoice.vectrolab.ru](https://voicevoice.vectrolab.ru) · Готовый `.dmg` — [последний релиз](https://github.com/sergekruff/voicevoice/releases/latest) или с лендинга.

## Возможности

- **Hotkey-диктовка** — `Fn` (по умолчанию), правый `⌥ Option` или `Caps Lock`. Зажал → говоришь → отпустил → текст в поле.
- **Локальный Whisper** (`large-v3-turbo`, 4-bit квантизация, ~632 МБ) через [WhisperKit](https://github.com/argmaxinc/WhisperKit). Инференс на Apple Neural Engine, ~10× быстрее реального времени на M4.
- **Авто-словарь правок** — после успешной вставки приложение ~5 минут отслеживает фокусное поле и, если правишь распознанный текст, запоминает пары `wrong → right`. На следующее распознавание правка применяется автоматически.
- **Fuzzy-matching** словаря с настраиваемым порогом — правка «клод код → Claude Code» сработает и на «клот кот», «клоуд код» и т. п.
- **Edit & Learn** для приложений, где Accessibility не отдаёт текст поля (Bitrix24, Max, Slack, Termius и т. п.) — ручное добавление правок в один клик из HUD.
- **Трёхуровневая вставка**: CGEvent ⌘V → AppleScript → AXUIElement direct write. Гарантия, что текст долетит куда угодно — Notes, Safari, Telegram, Termius, Slack, VS Code, Cursor, Claude Desktop, Max, Bitrix24…
- **TransientType-маркер** для клипборд-менеджеров (Maccy / Paste / PasteNow / Raycast) — наша промежуточная запись в буфер не засоряет историю.
- **Нормализация чисел** — `«один миллион четыреста двадцать пять»` → `1 425 689`, лишние пробелы и точки убираются.
- **Авто-эмодзи** (опционально) — добавляет один уместный смайл по триггер-словам: «спасибо» → 🙏, «поздравляю» → 🎉, «хаха» → 😄 и т. д.
- **HUD с результатом** + история последних 200 распознаваний + словарь правок с фильтрами.
- **Privacy-by-default** — ноль телеметрии, ноль облака, sandbox-совместимо, ad-hoc подписано стабильной идентичностью (TCC-permissions переживают пересборки).

## Требования

- macOS **13 Ventura** или новее (рекомендуется 14+)
- Apple Silicon (M1 / M2 / M3 / M4 / M5) — на Intel-Mac'ах Whisper падает на CPU и работает в 5–10 раз медленнее, интерактивная диктовка непрактична
- Xcode 15+ (только для сборки из исходников)
- Микрофон + разрешение Accessibility (запросит при первом запуске)

## Установка

### Готовый .dmg

Самый простой путь — скачать с лендинга: [voicevoice.vectrolab.ru](https://voicevoice.vectrolab.ru)

### Сборка из исходников

```bash
git clone https://github.com/sergekruff/voicevoice.git
cd voicevoice
./setup-signing.sh    # одноразово: создаёт self-signed identity для стабильных TCC-permissions
./build-app.sh        # собирает SwiftPM-таргет → .app-бандл → подпись
open build/VoiceVoice.app
```

Или через Xcode: `open Package.swift`, дождаться резолва WhisperKit + GRDB, нажать ▶︎ Run.

## Первый запуск

1. Откроется онбординг. Выдай разрешения:
   - **Микрофон** — кнопка «Запросить доступ».
   - **Accessibility** — нужно глобально слышать `Fn` и эмулировать `⌘V`. macOS откроет System Settings → Privacy & Security → Accessibility, нужно вручную поставить галочку рядом с VoiceVoice.
2. **Отключи системную диктовку:** System Settings → Keyboard → Dictation → off. Иначе macOS-овский overlay перехватит `Fn` поверх нашего.
3. WhisperKit при первом запуске скачает модель `large-v3-turbo` (~632 МБ) в `~/Library/Application Support/VoiceVoice/models/`. Прогресс виден в menu-bar статусе.

## Использование

1. Поставь курсор в любое поле ввода.
2. **Зажми Fn** → появится индикатор «Запись…».
3. Говори. Знаки препинания можно проговаривать («запятая», «точка», «вопросительный знак») — но Whisper и сам неплохо их расставляет.
4. **Отпусти Fn** → через ~0.5–1 с (M4) текст появится в поле.
5. Если что-то распозналось криво — авто-словарь сам подхватит правку, если ты исправишь слово вручную в течение 5 минут. Для приложений без AX-доступа — кнопка «Edit & Learn» в HUD.

## Где живут данные

```
~/Library/Application Support/VoiceVoice/
├── data.db           # SQLite (GRDB): словарь правок + история
└── models/           # WhisperKit модели CoreML
```

Удалить всё одной командой:
```bash
rm -rf "$HOME/Library/Application Support/VoiceVoice"
```

## Структура проекта

```
voicevoice/
├── Package.swift                 # SwiftPM манифест (WhisperKit, GRDB)
├── build-app.sh                  # сборка .app-бандла из CLI
├── make-dmg.sh                   # сборка установочного .dmg
├── setup-signing.sh              # создание self-signed identity
└── Sources/VoiceVoice/
    ├── VoiceVoiceApp.swift       # @main, MenuBarExtra
    ├── Resources/                # Info.plist, entitlements
    ├── Models/                   # AppSettings, CorrectionEntry, TranscriptionRecord
    ├── Storage/                  # GRDB Database, CorrectionStore, HistoryStore
    ├── Services/
    │   ├── AudioRecorder.swift   # AVAudioEngine 16 kHz моно
    │   ├── Transcriber.swift     # WhisperKit обёртка
    │   ├── HotkeyMonitor.swift   # глобальный CGEvent-tap
    │   ├── TextInserter.swift    # три тира paste + TransientType маркер
    │   ├── TextChangeWatcher.swift # авто-словарь через AX polling + BFS
    │   ├── ClipboardSnapshot.swift # снапшот/восстановление NSPasteboard
    │   ├── NumberNormalizer.swift
    │   ├── EmojiEnhancer.swift   # авто-смайлы
    │   ├── Tokenizer.swift       # Unicode word/non-word токены
    │   ├── DiffEngine.swift      # token-level LCS diff
    │   ├── CorrectionApplier.swift # применение словаря (exact + fuzzy)
    │   └── AppController.swift   # оркестратор
    └── Views/
        ├── SettingsView.swift    # настройки + HelpHint (?-подсказки)
        ├── ResultHUD.swift       # HUD после распознавания
        ├── EditAndLearnWindow.swift
        ├── MenuBarContent.swift
        ├── HistoryView.swift
        ├── DictionaryView.swift
        ├── OnboardingView.swift
        └── WindowOpener.swift
```

## Известные ограничения

- В приложениях с пустым / неполным AX-tree (Bitrix24 как CEF без AX, Max на Qt) **авто-обучение словаря недоступно** — нечего опрашивать. Зато вставка через ⌘V работает, плюс в HUD появляется кнопка Edit & Learn для ручного добавления правок.
- На внешних USB-клавиатурах `Fn` иногда не генерирует событие модификатора — переключись в настройках на правый `⌥ Option` или `Caps Lock`.
- При активной системной диктовке macOS её overlay перехватывает `Fn` — нужно выключить (см. онбординг).

## Стек

- **Swift 6** / **SwiftUI** / **AppKit** (MenuBarExtra, NSPanel, AXUIElement)
- [**WhisperKit**](https://github.com/argmaxinc/WhisperKit) (CoreML + ANE)
- [**GRDB**](https://github.com/groue/GRDB.swift) (SQLite-обёртка)

## Лицензия

MIT — см. [LICENSE](LICENSE). WhisperKit и GRDB — тоже MIT.

---

Сделано в [VectroLab](https://vectrolab.ru) · Екатеринбург
