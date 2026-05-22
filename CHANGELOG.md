# Changelog

Все заметные изменения в проекте VoiceVoice. Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версионирование — [SemVer](https://semver.org/lang/ru/).

## [Unreleased]

### Запланировано
- Голосовые команды над буфером обмена (`⌥ Option` удержание → LLM-преобразование текста).
- GitHub Actions для авто-сборки `.app` и `.dmg` по тегу `v*`.

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

[Unreleased]: https://github.com/sergekruf/voicevoice/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/sergekruf/voicevoice/releases/tag/v1.0.0
