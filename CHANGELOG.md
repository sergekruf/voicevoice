# Changelog

Все заметные изменения в проекте VoiceVoice. Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версионирование — [SemVer](https://semver.org/lang/ru/).

## [Unreleased]

### Запланировано
- Голосовые команды над буфером обмена (`⌥ Option` удержание → LLM-преобразование текста).
- GitHub Actions для авто-сборки `.app` и `.dmg` по тегу `v*`.

## [1.0.2] — 2026-05-25

### Исправлено
- **Длинные диктовки (40–60+ с) теряли куски в середине.** Без явного `chunkingStrategy` WhisperKit падал в встроенный seek-loop: при провале одного 30-секундного окна (temperature-fallback exhaustion или `noSpeechThreshold`) seek прыгал вперёд на полные 30 секунд, теряя весь контент окна. Теперь используется `chunkingStrategy: .vad` — аудио режется по тишине через `VADAudioChunker`, провал одного чанка не влияет на соседей.
- **Лимит выходных токенов**: `sampleLength` 224 → **448** (потолок Whisper). На плотной русской речи 224 иногда упирался в лимит и обрезал хвост окна.

### Изменено
- **Дашборд: счётчики «за всё время» вместо «последние 200»**. Таблица истории капится в 200 записей, и прежний `HistoryStore.stats()` считал по триммнутой таблице — счётчик «Всего расшифровок» упирался в 200 и не рос. Добавлены `AppStorage`-счётчики `lifetimeRecordsCount` / `lifetimeCharactersCount` / `lifetimeAudioSeconds` / `lifetimeProcessingMs` / `firstRecordAt`, инкрементируемые на каждой диктовке. При первом запуске на этой версии — одноразовая миграция: lifetime-поля заполняются из текущего содержимого БД (бэкфилл из имеющихся ≤ 200 записей).

## [1.0.1] — 2026-05-22

### Изменено
- `CFBundleShortVersionString` обновлён до `1.0.1`, `CFBundleVersion` — до `2`. Функциональных изменений по сравнению с бинарником, прикреплённым к релизу v1.0.0 после публикации, нет — релиз нужен, чтобы тег корректно соответствовал содержимому DMG.

### Добавлено к репо (после первичной публикации v1.0.0)
- `README.en.md` — полный английский перевод README.
- Бейджи в основном README: лицензия / версия / платформа / Apple Silicon / счётчик скачиваний.
- `CHANGELOG.md` и `CONTRIBUTING.md`.
- `.github/ISSUE_TEMPLATE/` — структурированные шаблоны bug-report и feature-request, плюс контакт-линки.
- `assets/social-preview.png` — 1280×640 для GitHub Settings → Social preview.
- 12 GitHub Topics для обнаруживаемости.

## [1.0.0] — 2026-05-22

Первый публичный релиз.

### Добавлено
- **Hotkey-диктовка** через удержание `Fn`, правого `⌥ Option` или `Caps Lock` (выбор в настройках).
- **Локальный Whisper** через [WhisperKit](https://github.com/argmaxinc/WhisperKit) — модель `large-v3-turbo` 4-bit на Apple Neural Engine, ~10× быстрее реального времени на M4.
- **Авто-обучение словаря** правок: ~5 минут после успешной вставки watcher следит за фокусным полем через AX и запоминает пары `wrong → right`.
- **Fuzzy-matching** словаря (Levenshtein с настраиваемым порогом).
- **Edit & Learn** — окно ручной правки распознанного текста с записью в словарь. Доступно из HUD для приложений без AX-доступа (Bitrix24, Max, Slack, Termius…).
- **Трёхуровневая вставка**: CGEvent ⌘V → AppleScript → AXUIElement direct write.
- **TransientType-маркер** на промежуточные записи в буфер — клипборд-менеджеры (Maccy, Paste, PasteNow, Raycast) их игнорируют.
- **Нормализация чисел** — числовые формы из речи преобразуются в цифры, лишние пробелы и точки убираются.
- **Авто-эмодзи** (opt-in) — один уместный смайл по триггер-словам: «спасибо» → 🙏, «поздравляю» → 🎉, «хаха» → 😄.
- **Тихий режим** — скрывает все HUD'ы и тосты, кроме индикатора записи.
- **Подсказки-`?`** возле каждой настройки с пружинной анимацией и кастомным popover'ом.
- **История последних 200 распознаваний** + словарь правок с фильтрами.
- **Privacy-by-default** — ноль телеметрии, ноль облака.

### Стек
- Swift 6 / SwiftUI / AppKit
- WhisperKit + CoreML/ANE
- GRDB (SQLite-обёртка)

[Unreleased]: https://github.com/sergekruf/voicevoice/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/sergekruf/voicevoice/releases/tag/v1.0.2
[1.0.1]: https://github.com/sergekruf/voicevoice/releases/tag/v1.0.1
[1.0.0]: https://github.com/sergekruf/voicevoice/releases/tag/v1.0.0
