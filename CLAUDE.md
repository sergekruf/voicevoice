# VoiceVoice — CLAUDE.md

## Что это

Голосовая диктовка для macOS с локальным распознаванием (без облака): зажал `Fn` → говоришь →
отпустил → текст вставляется в активное поле любого приложения. Инференс на Apple Neural Engine,
два движка: **GigaAM-v3 e2e RNNT** (русский, лучшее качество; своя Core ML-конвертация, beam search +
подсказка терминов из словаря) и **Parakeet TDT v3** (FluidAudio, 25 языков, дефолт для новых установок).
С 1.1.8 удалены WhisperKit, LLM-постредактор (Qwen/MLX), Sage и нейро-пунктуация RUPunct — замер показал,
что качество держат движок + словарь правок, а модели давали секунды задержки и гигабайты.
Публичный репозиторий: github.com/sergekruf/voicevoice, лендинг: voicevoice.vectrolab.ru. MIT.

## Стек и структура

- Swift 5.10, SwiftPM (`Package.swift`, БЕЗ .xcodeproj), macOS 14+, только Apple Silicon (arm64).
- Зависимости: FluidAudio (Parakeet), GRDB (SQLite: история + словарь правок). Всё. Приложение ~14 МБ.
- `Sources/VoiceVoice/`:
  - `Services/` — вся логика: `AppController` (оркестратор), `GigaAMTranscriber` (+ `RNNTBeamSearch`),
    `ParakeetTranscriber`, `Transcriber` (общее для движков: нарезка по паузам со своим EnergyVAD,
    склейка кусков, сверка стыков, блоклист галлюцинаций), `AudioRecorder`, `HotkeyMonitor`,
    `TextInserter` (3 уровня вставки: CGEvent ⌘V → AppleScript → AX), `CorrectionApplier` +
    `TextChangeWatcher` (авто-словарь правок), `DictionaryAudit` (ревизия, в т.ч. по расписанию), `NumberNormalizer`,
    `PunctuationFixer` (склейка союзов, потерянный «?»), `AudioFileDecoder`, `AudioArchive`.
  - `Views/` — SwiftUI: HUD, онбординг, настройки, история, словарь, `FileTranscribeWindow`.
  - `Models/`, `Storage/` — настройки, записи, GRDB-обёртки.
  - `Resources/GigaAM/gigaam_rnnt_pieces.json` — куски SentencePiece с оценками (для подсказки терминов).

## Крупные артефакты — НЕ трогать и НЕ индексировать (~3 ГБ всего)

- `.build/` (~2.2 ГБ) — артефакты SwiftPM + checkouts зависимостей. Не читать, не удалять без нужды.
- `.mltools/` — python venv с torch/coremltools, скрипты конвертации GigaAM (`convert_gigaam_rnnt.py`,
  эксперименты `gigaam25/`) и замеры качества (`bench_window.py`, `bench_llm_vs_engine.py`).
  Локальный инструментарий, в git не идёт.
- `build/` — собранные `VoiceVoice.app` (~14 МБ) и `VoiceVoice.dmg` (~5 МБ).
- STT-модели (~600 МБ каждая) качаются в `~/Library/Application Support/VoiceVoice/models/`.

## Сборка и запуск

```bash
./setup-signing.sh   # одноразово: self-signed identity "VoiceVoiceDev" (стабильные TCC-permissions)
./build-app.sh       # swift build (release, arm64) → build/VoiceVoice.app → codesign
open build/VoiceVoice.app
./make-dmg.sh        # опционально: .dmg
```

Или в Xcode: `open Package.swift` → Run. Логи: `log stream --predicate 'process == "VoiceVoice"' --info`.

## Текущее состояние

- Одна ветка `main`. История изменений — `CHANGELOG.md` (Keep a Changelog, на русском).

## Особенности и грабли

- **iCloud ломает codesign**: проект лежит в ~/Documents (iCloud внедряет xattr), поэтому
  `build-app.sh` собирает бандл в `/tmp` и только потом переносит через `ditto`. Не менять эту схему.
- **Подпись**: без identity "VoiceVoiceDev" — fallback на ad-hoc, тогда TCC-разрешения
  (Accessibility/микрофон) слетают при каждой пересборке.
- **Конфликт с системной диктовкой**: у пользователя должна быть выключена диктовка macOS,
  иначе её overlay перехватывает `Fn`.
- **Установка в /Applications**: `ditto` дописывает поверх и НЕ удаляет лишние файлы — после удаления
  ресурсов старое приложение сначала убрать (в Корзину), потом копировать.
- **Отладочные флаги** (`VoiceVoice --…`): `--transcribe-test a.wav …` (env `VOICEVOICE_ENGINE=parakeet`,
  `VOICEVOICE_GIGAAM_BEAM`, `VOICEVOICE_GIGAAM_HOTWORDS`, `VOICEVOICE_GIGAAM_MODEL_DIR`), `--seam-test`,
  `--merge-test`, `--question-test [history]`, `--diff-test`, `--learn-test`, `--dict-sim`, `--audit-dict`,
  `--update-test`.
- `PROMOTION.md`, `NOTES.md`, `TODO.md` — личные заметки, в публичный репозиторий не коммитить (.gitignore).
- `Package.swift` требует macOS 14, README заявляет 13+ — при правках версий сверяться с Package.swift.
