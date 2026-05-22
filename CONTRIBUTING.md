# Contributing to VoiceVoice

Спасибо, что хотите помочь! Пара коротких правил, чтобы PR'ы и issue были полезны.

## Issues

- **Bug report** — пожалуйста, заполните шаблон `.github/ISSUE_TEMPLATE/bug.yml`. Минимум: версия macOS, чип (M1/M2/…), модель Whisper, поведение vs ожидание, лог из `~/Library/Logs/VoiceVoice/voicevoice.log` за последнюю минуту.
- **Feature request** — заполните шаблон `.github/ISSUE_TEMPLATE/feature.yml`. Опишите use-case, который сейчас неудобен.

## Pull requests

1. Откройте issue с обсуждением **до начала работы**, если изменения нетривиальные (новая фича, изменение архитектуры). Это сэкономит время.
2. Один PR — одно изменение. Не смешивайте рефакторинг и новую фичу.
3. Стиль кода — [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/). Запускайте `swift format` перед коммитом, если есть в окружении.
4. Сборка через `./build-app.sh` должна проходить без warnings. Существующие warning'и в `TextChangeWatcher.swift` (про actor-isolation) — известные, исправляются отдельно.
5. Описание PR — что меняется, **зачем**, как тестировали. Скриншот / GIF приветствуется.
6. Совместимость: macOS 13+, Apple Silicon. Не вводите зависимости от macOS 14+ API без обсуждения.

## Локальная разработка

```bash
git clone https://github.com/sergekruff/voicevoice.git
cd voicevoice
./setup-signing.sh    # одноразово
./build-app.sh        # сборка + ad-hoc подпись стабильной идентичностью
open build/VoiceVoice.app
```

`setup-signing.sh` создаёт **стабильную self-signed identity** `VoiceVoiceDev` в Keychain, чтобы выданные TCC-разрешения (Microphone, Accessibility) переживали пересборку. Без этого macOS будет спрашивать разрешения заново на каждый билд.

## Структура

См. раздел «Структура проекта» в [README](README.md).

## Лицензия

Делая PR, вы соглашаетесь, что ваш код будет распространяться под [MIT-лицензией](LICENSE) этого проекта.
