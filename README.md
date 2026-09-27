# VoiceVoice

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/sergekruf/voicevoice)](https://github.com/sergekruf/voicevoice/releases/latest)
[![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-orange?logo=apple)](#требования)
[![Downloads](https://img.shields.io/github/downloads/sergekruf/voicevoice/total?label=downloads)](https://github.com/sergekruf/voicevoice/releases)

🇬🇧 [Read in English](README.en.md)

**Голосовая диктовка для macOS с локальным распознаванием речи.** Зажал `Fn`, наговорил, отпустил — и текст появляется в любом активном поле ввода. Распознавание идёт целиком на твоей машине через Apple Neural Engine — ни одна фраза не уходит в облако.

Лендинг: [voicevoice.vectrolab.ru](https://voicevoice.vectrolab.ru) · Готовый `.dmg` — [последний релиз](https://github.com/sergekruf/voicevoice/releases/latest) или с лендинга.

## Возможности

- **Hotkey-диктовка** — `Fn` (по умолчанию), правый `⌥ Option` или `Caps Lock`. Зажал → говоришь → отпустил → текст в поле.
- **Два локальных движка на выбор**:
  - [**GigaAM-v3**](https://github.com/salute-developers/GigaAM) (Сбер) — лучшее качество на русском: сам ставит знаки препинания и пишет числа цифрами. Декодирование с поиском по нескольким вариантам и подсказкой терминов из вашего словаря (Claude, API, ФБС…). Модель ~400 МБ.
  - [**Parakeet TDT v3**](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) через [FluidAudio](https://github.com/FluidInference/FluidAudio) — быстрый, 25 европейских языков. Модель ~600 МБ.

  Модель выбранного движка скачивается при первом запуске; инференс на Apple Neural Engine, фраза распознаётся за 0,1–0,5 с. Приложение весит ~14 МБ и занимает ~80 МБ памяти.
- **Длинные диктовки без рваных фраз** — запись режется по паузам, а стыки кусков перепроверяются с контекстом: ложные точки, «?» и заглавные посреди предложения убираются. Потерянный «?» восстанавливается по грамматике («Можем ли мы…», «…или это всё»).
- **Авто-словарь правок** — после успешной вставки приложение ~5 минут отслеживает фокусное поле и, если правишь распознанный текст, запоминает пары `wrong → right`. На следующее распознавание правка применяется автоматически.
- **Fuzzy-matching** словаря с настраиваемым порогом — правка «клод код → Claude Code» сработает и на «клот кот», «клоуд код» и т. п. Обычные русские слова нечёткое сравнение не трогает.
- **Ревизия словаря** — по расписанию находит правила, которые могут портить текст (замены обычных слов, дубликаты), и предлагает их убрать.
- **Edit & Learn** для приложений, где Accessibility не отдаёт текст поля (Bitrix24, Max, Slack, Termius и т. п.) — ручное добавление правок в один клик из HUD.
- **Трёхуровневая вставка**: CGEvent ⌘V → AppleScript → AXUIElement direct write. Гарантия, что текст долетит куда угодно — Notes, Safari, Telegram, Termius, Slack, VS Code, Cursor, Claude Desktop, Max, Bitrix24…
- **TransientType-маркер** для клипборд-менеджеров (Maccy / Paste / PasteNow / Raycast) — наша промежуточная запись в буфер не засоряет историю.
- **Нормализация чисел** — «две тысячи пятьсот тридцать два» → `2532`, «с двадцать четвёртого по сороковой» → «с 24-го по 40-й», «три с половиной» → `3,5`.
- **HUD с результатом** + история последних 200 распознаваний + словарь правок с фильтрами.
- **Privacy-by-default** — ноль телеметрии, ноль облака, sandbox-совместимо, ad-hoc подписано стабильной идентичностью (TCC-permissions переживают пересборки).

## Требования

- macOS **14 Sonoma** или новее
- Apple Silicon (M1 / M2 / M3 / M4 / M5) — модели работают на Neural Engine; сборки под Intel нет
- Xcode 15+ (только для сборки из исходников)
- Микрофон + разрешение Accessibility (запросит при первом запуске)

## Установка

### Готовый .dmg

Самый простой путь — скачать с лендинга: [voicevoice.vectrolab.ru](https://voicevoice.vectrolab.ru)

### Сборка из исходников

```bash
git clone https://github.com/sergekruf/voicevoice.git
cd voicevoice
./setup-signing.sh    # одноразово: создаёт self-signed identity для стабильных TCC-permissions
./build-app.sh        # собирает SwiftPM-таргет → .app-бандл → подпись
open build/VoiceVoice.app
```

Или через Xcode: `open Package.swift`, дождаться резолва FluidAudio + GRDB, нажать ▶︎ Run.

## Первый запуск

1. Откроется онбординг. Выдай разрешения:
   - **Микрофон** — кнопка «Запросить доступ».
   - **Accessibility** — нужно глобально слышать `Fn` и эмулировать `⌘V`. macOS откроет System Settings → Privacy & Security → Accessibility, нужно вручную поставить галочку рядом с VoiceVoice.
2. **Отключи системную диктовку:** System Settings → Keyboard → Dictation → off. Иначе macOS-овский overlay перехватит `Fn` поверх нашего.
3. При первом запуске скачается модель выбранного движка (~400–600 МБ). Движок меняется в Настройках: GigaAM — для русского, Parakeet — для других языков. Прогресс виден в menu-bar статусе.

## Использование

1. Поставь курсор в любое поле ввода.
2. **Зажми Fn** → появится индикатор «Запись…».
3. Говори. Знаки препинания проговаривать не нужно — GigaAM расставляет их сам.
4. **Отпусти Fn** → через ~0.5–1 с (M4) текст появится в поле.
5. Если что-то распозналось криво — авто-словарь сам подхватит правку, если ты исправишь слово вручную в течение 5 минут. Для приложений без AX-доступа — кнопка «Edit & Learn» в HUD.

## Где живут данные

```
~/Library/Application Support/VoiceVoice/
├── data.db           # SQLite (GRDB): словарь правок + история
└── models/GigaAM/    # модель GigaAM (Core ML); модель Parakeet — в ~/Library/Application Support/FluidAudio
```

Удалить всё одной командой:
```bash
rm -rf "$HOME/Library/Application Support/VoiceVoice"
```

## Структура проекта

```
voicevoice/
├── Package.swift                 # SwiftPM манифест (FluidAudio, GRDB)
├── build-app.sh                  # сборка .app-бандла из CLI
├── make-dmg.sh                   # сборка установочного .dmg
├── setup-signing.sh              # создание self-signed identity
└── Sources/VoiceVoice/
    ├── VoiceVoiceApp.swift       # @main, MenuBarExtra
    ├── Resources/                # Info.plist, entitlements, куски словаря GigaAM
    ├── Models/                   # AppSettings, CorrectionEntry, TranscriptionRecord
    ├── Storage/                  # GRDB Database, CorrectionStore, HistoryStore
    ├── Services/
    │   ├── AudioRecorder.swift   # AVAudioEngine 16 kHz моно
    │   ├── GigaAMTranscriber.swift # GigaAM-v3 на Core ML (энкодер на ANE)
    │   ├── RNNTBeamSearch.swift  # поиск по вариантам + подсказка терминов
    │   ├── ParakeetTranscriber.swift # Parakeet через FluidAudio
    │   ├── Transcriber.swift     # общее: нарезка по паузам, склейка кусков, стыки
    │   ├── PunctuationFixer.swift # склейка рубленых фраз, потерянный «?»
    │   ├── HotkeyMonitor.swift   # глобальный CGEvent-tap
    │   ├── TextInserter.swift    # три тира paste + TransientType маркер
    │   ├── TextChangeWatcher.swift # авто-словарь через AX polling + BFS
    │   ├── ClipboardSnapshot.swift # снапшот/восстановление NSPasteboard
    │   ├── NumberNormalizer.swift
    │   ├── Tokenizer.swift       # Unicode word/non-word токены
    │   ├── DiffEngine.swift      # token-level LCS diff
    │   ├── CorrectionApplier.swift # применение словаря (exact + fuzzy)
    │   ├── DictionaryAudit.swift # ревизия словаря
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
- [**GigaAM-v3**](https://github.com/salute-developers/GigaAM) (сконвертирована в Core ML, энкодер на ANE)
- [**FluidAudio**](https://github.com/FluidInference/FluidAudio) (Parakeet TDT v3)
- [**GRDB**](https://github.com/groue/GRDB.swift) (SQLite-обёртка)

## Лицензия

MIT — см. [LICENSE](LICENSE). GigaAM и GRDB — MIT, FluidAudio — Apache 2.0, модель Parakeet — CC-BY-4.0.

---

Сделано в [VectroLab](https://vectrolab.ru) · Екатеринбург
