# RUPunct — ресурсы нейро-пунктуации

Эта папка бандлится в `VoiceVoice.app` (объявлена ресурсом в `Package.swift`) и питает
опциональную нейро-пунктуацию (Настройки → «Нейро-пунктуация», по умолчанию выключена).

## Что лежит в git

- `tokenizer.json`, `vocab.txt`, `tokenizer_config.json`, `special_tokens_map.json` —
  WordPiece-токенизатор rubert-tiny2 (загружается через swift-transformers).
- `labels.json` — маппинг классов модели (пунктуация + регистр).

## Чего в git НЕТ

- `RUPunct_small.mlpackage` (~56 МБ) — Core ML конвертация модели
  [RUPunct/RUPunct_small](https://huggingface.co/RUPunct/RUPunct_small)
  (token-classifier на базе rubert-tiny2). В репозиторий не коммитится из-за размера.

**Без модели проект собирается и работает** — `RUPunctService` при её отсутствии
переходит в состояние `.failed`, и текст проходит без нейро-пунктуации (работает
обычный правиловый `PunctuationFixer`).

## Как получить модель

Конвертация из PyTorch в Core ML делается стандартным пайплайном
`transformers` + `coremltools` (~10 строк: загрузить
`AutoModelForTokenClassification` c HuggingFace, обернуть в trace по входам
`input_ids`/`attention_mask` и сохранить `.mlpackage` c выходом `logits`
формы `[1, seq, num_labels]`). Готовый `RUPunct_small.mlpackage` кладётся в эту
папку рядом с README — и при следующей сборке фича активна.
