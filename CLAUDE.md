# VoiceVoice — CLAUDE.md

## Что это

Голосовая диктовка для macOS с локальным распознаванием (без облака): зажал `Fn` → говоришь →
отпустил → текст вставляется в активное поле любого приложения. Инференс на Apple Neural Engine,
два движка на выбор: Parakeet TDT v3 (FluidAudio, дефолт с 1.1.1) и Whisper large-v3-turbo (WhisperKit).
Публичный репозиторий: github.com/sergekruf/voicevoice, лендинг: voicevoice.vectrolab.ru. MIT.

## Стек и структура

- Swift 5.10, SwiftPM (`Package.swift`, БЕЗ .xcodeproj), macOS 14+, только Apple Silicon (arm64).
- Зависимости: WhisperKit, FluidAudio (Parakeet), GRDB (SQLite: история + словарь правок),
  swift-transformers (Tokenizers для RUPunct).
- `Sources/VoiceVoice/`:
  - `Services/` — вся логика: `AppController` (оркестратор), `Transcriber` / `ParakeetTranscriber`,
    `AudioRecorder`, `HotkeyMonitor`, `TextInserter` (3 уровня вставки: CGEvent ⌘V → AppleScript → AX),
    `RUPunctService` (нейро-пунктуация), `CorrectionApplier` + `TextChangeWatcher` (авто-словарь правок),
    `NumberNormalizer`, `PunctuationFixer`, `AudioFileDecoder` (транскрипция файлов).
  - `Views/` — SwiftUI: HUD, онбординг, настройки, история, словарь, `FileTranscribeWindow`.
  - `Models/`, `Storage/` — настройки, записи, GRDB-обёртки.
  - `Resources/RUPunct/` — Core ML модель пунктуации (~56 МБ) + токенизатор; бандлится в .app
    через `Bundle.module`, но в git НЕ коммитится (.gitignore).

## Крупные артефакты — НЕ трогать и НЕ индексировать (~3 ГБ всего)

- `.build/` (~2.2 ГБ) — артефакты SwiftPM + checkouts зависимостей. Не читать, не удалять без нужды.
- `.mltools/` (~825 МБ) — python venv с torch (766 МБ) и скрипты конвертации RUPunct в Core ML
  (`convert.py`, `eval_rupunct.py`). Локальный инструментарий, в git не идёт.
- `build/` (~83 МБ) — собранные `VoiceVoice.app` и `VoiceVoice.dmg`.
- `Sources/VoiceVoice/Resources/RUPunct/` (~56 МБ) — модель нужна для сборки, но gitignored.
- STT-модели (~600 МБ каждая) качаются в `~/Library/Application Support/VoiceVoice/models/`.

## Сборка и запуск

```bash
./setup-signing.sh   # одноразово: self-signed identity "VoiceVoiceDev" (стабильные TCC-permissions)
./build-app.sh       # swift build (release, arm64) → build/VoiceVoice.app → codesign
open build/VoiceVoice.app
./make-dmg.sh        # опционально: .dmg
```

Или в Xcode: `open Package.swift` → Run. Логи: `log stream --predicate 'process == "VoiceVoice"' --info`.

## Текущее состояние (git)

- Одна ветка `main`, рабочее дерево чистое. Последний коммит — WIP к **1.1.2**:
  транскрипция аудиофайлов, нейро-пунктуация RUPunct (тоггл, дефолт OFF, только русский),
  фиксы склейки чанков (`joinChunkTexts`) и грейс-период буфера обмена (~30 с).
- Запланировано (CHANGELOG Unreleased): голосовые LLM-команды над буфером, GitHub Actions для релизов.
- История изменений подробно ведётся в `CHANGELOG.md` (Keep a Changelog, на русском).

## Особенности и грабли

- **iCloud ломает codesign**: проект лежит в ~/Documents (iCloud внедряет xattr), поэтому
  `build-app.sh` собирает бандл в `/tmp` и только потом переносит через `ditto`. Не менять эту схему.
- **Подпись**: без identity "VoiceVoiceDev" — fallback на ad-hoc, тогда TCC-разрешения
  (Accessibility/микрофон) слетают при каждой пересборке.
- **Конфликт с системной диктовкой**: у пользователя должна быть выключена диктовка macOS,
  иначе её overlay перехватывает `Fn`.
- **Галлюцинации Whisper** на тишине («Субтитры сделал DimaTorzok» и т.п.) — фильтруются
  `Transcriber.stripHallucinations` + редактируемый блоклист в настройках.
- `PROMOTION.md`, `NOTES.md`, `TODO.md` — личные заметки, в публичный репозиторий не коммитить (.gitignore).
- `Package.swift` требует macOS 14, README заявляет 13+ — при правках версий сверяться с Package.swift.
