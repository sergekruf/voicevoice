import SwiftUI
import AppKit

@main
struct VoiceVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var transcriber = Transcriber.shared
    @ObservedObject private var parakeet = ParakeetTranscriber.shared
    @ObservedObject private var gigaam = GigaAMTranscriber.shared
    @ObservedObject private var settings = AppSettings.shared

    /// State of whichever engine is currently selected.
    private var engineState: Transcriber.ModelState {
        switch settings.sttEngine {
        case .whisperKit: return transcriber.state
        case .parakeet: return parakeet.state
        case .gigaAM: return gigaam.state
        }
    }

    var body: some View {
        switch controller.state {
        case .recording: Image(systemName: "mic.fill").foregroundStyle(.red)
        case .transcribing: Image(systemName: "waveform")
        case .complete: Image(systemName: "mic")
        case .error: Image(systemName: "mic.slash")
        case .idle:
            switch engineState {
            case .downloading, .loading, .notLoaded: Image(systemName: "mic.badge.plus")
            case .error: Image(systemName: "mic.slash")
            case .ready: Image(systemName: "mic")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we're a UIElement (no Dock icon) regardless of bundle Info.plist quirks.
        NSApp.setActivationPolicy(.accessory)

        // Скрытый отладочный режим: `VoiceVoice --sage-test "текст"` — прогоняет текст
        // через SageCorrectorService (полный Swift-путь: токенизатор → bias → greedy →
        // диф-гард) и завершается, минуя bootstrap. Для сверки с Python-эталоном
        // (.mltools/eval_sage.py) без записи с микрофона.
        if let idx = CommandLine.arguments.firstIndex(of: "--sage-test"),
           idx + 1 < CommandLine.arguments.count {
            let text = CommandLine.arguments[idx + 1]
            Task { @MainActor in
                // 3 прогона: №1 показывает холодный старт (компиляция GPU-пайплайнов),
                // №2–3 — устоявшуюся скорость резидентного процесса (как в жизни).
                var out = ""
                for run in 1...3 {
                    let t0 = Date()
                    out = await SageCorrectorService.shared.correct(text)
                    print("SAGE-TEST run \(run): \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                }
                print("SAGE-TEST IN : \(text)")
                print("SAGE-TEST OUT: \(out)")
                exit(0)
            }
            return
        }

        // Скрытый отладочный режим: `VoiceVoice --transcribe-test a.wav b.wav …` —
        // прогоняет аудиофайлы через GigaAM (нарезка, стыки, склейка) без микрофона.
        if let idx = CommandLine.arguments.firstIndex(of: "--transcribe-test"),
           idx + 1 < CommandLine.arguments.count {
            let paths = Array(CommandLine.arguments[(idx + 1)...])
            Task { @MainActor in
                for path in paths {
                    do {
                        let audio = try AudioFileDecoder.decode(url: URL(fileURLWithPath: path))
                        let out = await GigaAMTranscriber.shared.transcribe(audio: audio)
                        print("TRANSCRIBE-TEST \((path as NSString).lastPathComponent): \(out)")
                    } catch {
                        print("TRANSCRIBE-TEST \(path): \(error.localizedDescription)")
                    }
                }
                exit(0)
            }
            return
        }

        // Скрытый отладочный режим: `VoiceVoice --seam-test` — сверка стыка аудио-кусков
        // с контекстным прогоном (Transcriber.reconcileSeam) и перенос «?».
        if CommandLine.arguments.contains("--seam-test") {
            let cases: [(String, String, String, Transcriber.SeamVerdict)] = [
                ("Скажи, как можно настроить здесь маршрутизацию?", "Трафика, чтобы зарубежные сайты шли через VPN.",
                 "Скажи, как можно настроить здесь маршрутизацию трафика, чтобы зарубежные сайты шли через VP",
                 .continuation(left: "Скажи, как можно настроить здесь маршрутизацию",
                               right: "трафика, чтобы зарубежные сайты шли через VPN.", removedQuestion: true)),
                ("Девушка бежит по набережной в этой ветровке.", "В одном из городов России, и мне понравился цвет.",
                 "...девушка бежит по набережной в этой ветровке в одном из городов России, и мне очень",
                 .continuation(left: "Девушка бежит по набережной в этой ветровке",
                               right: "в одном из городов России, и мне понравился цвет.", removedQuestion: false)),
                ("Российские сайты, типа Ozon.", "Wildberries, How и другие магазины шли напрямую",
                 "российские сайты, типа Ozon, Wildberries, How и другие",
                 .continuation(left: "Российские сайты, типа Ozon,",
                               right: "Wildberries, How и другие магазины шли напрямую", removedQuestion: false)),
                ("Включая акты и счета за прошлый месяц.", "Завтра утром отправим оригиналы.",
                 "включая акты и счета за прошлый месяц. Завтра утром отправим оригиналы курьером", .boundary),
                ("Ты придёшь туда к десяти утра?", "Если нет, напиши заранее.",
                 "Ты придёшь туда к 10:00 утра? Если нет, напиши мне заранее", .boundary),
                // Слово у стыка распознано вторым прогоном чуть иначе, оба соседа совпали.
                ("Настроить здесь маршрутизацию?", "Трафика, чтобы сайты шли",
                 "настроить здесь маршрутизации трафика, чтобы сайты шли",
                 .continuation(left: "Настроить здесь маршрутизацию", right: "трафика, чтобы сайты шли",
                               removedQuestion: true)),
                ("Выйти на маркетплейсы Ozon.", "Wildberres и Яндекс Маркет одновременно",
                 "выйти на маркетплейсы Ozon, Wildberrieces и ЯндексМаркет одновременно",
                 .continuation(left: "Выйти на маркетплейсы Ozon,", right: "Wildberres и Яндекс Маркет одновременно",
                               removedQuestion: false)),
                // Созвучное слово, но сосед совпал только один — не трогаем.
                ("Настроить здесь маршрутизацию?", "Трафика, чтобы сайты шли",
                 "как настроить маршрутизации трафика и сайты", .unmatched),
                // Совпала только пара без соседей — случайность, не трогаем.
                ("Потом поедем в офис.", "В понедельник созвонимся.", "и офис в пятницу", .unmatched),
            ]
            var ok = 0
            for (left, right, context, expected) in cases {
                let got = Transcriber.reconcileSeam(left: left, right: right, context: context)
                if got == expected { ok += 1 }
                print("\(got == expected ? "PASS" : "FAIL")  «\(left) | \(right)» → \(got)"
                      + (got == expected ? "" : "\n      ожидалось: \(expected)"))
            }
            let moves: [(String, String, Bool)] = [
                ("трафика, чтобы сайты шли напрямую. Потом проверим.", "трафика, чтобы сайты шли напрямую? Потом проверим.", true),
                ("сайты шли через ozon.ru и 10.5 раз", "сайты шли через ozon.ru и 10.5 раз", false),
                ("напиши заранее! Потом созвонимся.", "напиши заранее! Потом созвонимся.", true),
            ]
            for (input, expected, expectedDone) in moves {
                let got = Transcriber.moveQuestionMark(into: input)
                let pass = got.text == expected && got.done == expectedDone
                if pass { ok += 1 }
                print("\(pass ? "PASS" : "FAIL")  перенос «?»: \(got.text) (done=\(got.done))")
            }
            print("\nверно: \(ok)/\(cases.count + moves.count)")
            exit(0)
        }

        // Скрытый отладочный режим: `VoiceVoice --merge-test` — склейка продолжений
        // после точки и вопросительного знака (PunctuationFixer.mergeContinuationClauses).
        if CommandLine.arguments.contains("--merge-test") {
            let cases: [(String, String)] = [
                ("Почему в последней фразе перед последним предложением поставилась точка? Хотя по смыслу это целое предложение.",
                 "Почему в последней фразе перед последним предложением поставилась точка, хотя по смыслу это целое предложение?"),
                ("Сделаем завтра. Хотя можно и сегодня.", "Сделаем завтра, хотя можно и сегодня."),
                ("Отправил заявку. Потому что срок горит.", "Отправил заявку, потому что срок горит."),
                ("Добавь фильтр. Чтобы он не терялся при возврате.", "Добавь фильтр, чтобы он не терялся при возврате."),
                ("Там заложена маржинальность. Но покупатель увидит цену на комплект.",
                 "Там заложена маржинальность, но покупатель увидит цену на комплект."),
                ("Почему ушёл? Потому что устал.", "Почему ушёл? Потому что устал."),
                ("Ты придёшь? Если нет, напиши.", "Ты придёшь? Если нет, напиши."),
                ("Договорились! Хотя сроки жмут.", "Договорились! Хотя сроки жмут."),
                ("Хотя это неважно.", "Хотя это неважно."),
                ("Проверь остатки. Вопрос закрыт?", "Проверь остатки. Вопрос закрыт?"),
                ("Сделай отчёт. Отправь его Николаю.", "Сделай отчёт. Отправь его Николаю."),
            ]
            var ok = 0
            for (input, expected) in cases {
                let got = PunctuationFixer.mergeContinuationClauses(input)
                if got == expected { ok += 1 }
                print("\(got == expected ? "PASS" : "FAIL")  \(got)\(got == expected ? "" : "\n      ожидалось: \(expected)")")
            }
            print("\nверно: \(ok)/\(cases.count)")
            exit(0)
        }

        // Скрытый отладочный режим: `VoiceVoice --diff-test` — что попадёт в словарь
        // при правке распознанного текста (путь Edit & Learn: raw → final).
        if CommandLine.arguments.contains("--diff-test") {
            let cases: [(String, String, String)] = [
                ("Найди бота вент система по Ozon", "Найди бота Вентсистема по Ozon",
                 "вент система → Вентсистема"),
                ("Перейти в колонку и того", "Перейти в колонку итого", "и того → итого"),
                ("Проверь фрисовые шапки", "Проверь флисовые шапки", "фрисовые → флисовые"),
                ("Отправь на ля моду сегодня", "Отправь на Lamoda сегодня", "ля моду → Lamoda"),
                ("Посчитай себе с товара", "Посчитай себестоимость товара", "себе с → себестоимость"),
                ("Мне нужно подумать механизм как это сделать",
                 "Надо придумать способ реализации", "(переписывание — не одна пара)"),
            ]
            for (raw, final, expect) in cases {
                let signals = CorrectionLearner.extract(raw: raw, applied: raw, final: final,
                                                        autoApplied: [])
                let got = signals.confirmations
                    .map { "«\($0.wrong)» → «\($0.right)»" }.joined(separator: ", ")
                print("ожидалось \(expect)\n  получено: \(got.isEmpty ? "(ничего)" : got)")
            }
            exit(0)
        }

        // Скрытый отладочный режим: `VoiceVoice --mine-history` — печатает кандидатов
        // в словарь из истории (то же, что кнопка «Разбор диктовок…»), плюс самотест
        // извлечения пар на синтетике, т.к. у старых записей сырого текста нет.
        if CommandLine.arguments.contains("--mine-history") {
            let records = HistoryStore.shared.recent(limit: 500)
            let withEngine = records.filter { !$0.engineText.isEmpty }
            let candidates = HistoryMining.candidates(from: records,
                                                      existing: CorrectionStore.shared.allOrdered())
            print("MINE: записей \(records.count), с сырым текстом движка \(withEngine.count), кандидатов \(candidates.count)")
            for c in candidates { print("  «\(c.wrong)» → «\(c.right)» ×\(c.count)  — \(c.example)") }

            print("\n=== самотест извлечения пар ===")
            let cases: [(String, String, String)] = [
                ("Найди вотов по Ozon и дай ответ", "Найди ботов по Ozon и дай ответ", "вотов→ботов"),
                ("Перейти в колонку и того", "Перейти в колонку итого", "и того→итого"),
                ("Руководство по фронтенту", "Руководство по фронтенду", "фронтенту→фронтенду"),
                ("Отправь отчёт сегодня", "Отправь отчёт сегодня.", "(только пунктуация — не берём)"),
                ("по ещё каким-то задаче", "по ещё каким-то задачам", "(обычное слово — не берём)"),
            ]
            for (before, after, expect) in cases {
                let pairs = HistoryMining.replacements(from: before, to: after)
                    .filter { HistoryMining.isWorthLearning(wrong: $0.0, right: $0.1) }
                let got = pairs.map { "\($0.0)→\($0.1)" }.joined(separator: ", ")
                print("  ожидалось \(expect):  получено [\(got)]")
            }
            exit(0)
        }

        // Скрытый отладочный режим: `VoiceVoice --learn-test` — прогоняет контрольные
        // пары через фильтр захвата автословаря (какие правки попадут в словарь).
        if CommandLine.arguments.contains("--learn-test") {
            let good = [("фрисовые", "флисовые"), ("обс", "ФБС"), ("клуд", "Клод"),
                        ("валберес", "вайлдберриз"), ("влк", "в ЛК"), ("пеке", "ПЭК"),
                        ("чпек", "jpg"), ("сейлеры", "селлеры"), ("здэк", "СДЭК"),
                        ("клод код", "Claude Code")]
            let bad = [("боты", "бота"), ("задаче", "задачам"), ("листа", "к листу"),
                       ("упакуют", "пакуют"), ("обновить", "Обнови"), ("настроено", "настроен"),
                       ("поехала", "поехало"), ("кода", "когда"), ("себе", "себес"),
                       ("сегодняшние", "сегодняшнего"), ("аппаратном", "платном")]
            let w = TextChangeWatcher.shared
            var ok = 0
            print("=== ДОЛЖНЫ учиться (ослышки) ===")
            for (a, b) in good {
                let learn = w.isLearnable(wrong: a, right: b)
                if learn { ok += 1 }
                print("  \(learn ? "учим  " : "ПРОПУСК") «\(a)» → «\(b)»")
            }
            print("=== НЕ должны учиться (контекстные правки) ===")
            for (a, b) in bad {
                let learn = w.isLearnable(wrong: a, right: b)
                if !learn { ok += 1 }
                print("  \(learn ? "УЧИМ!!" : "отсеян") «\(a)» → «\(b)»")
            }
            print("\nверно: \(ok)/\(good.count + bad.count)")
            exit(0)
        }

        // Скрытый отладочный режим: `VoiceVoice --audit-dict` — печатает ревизию
        // словаря правок (то же, что кнопка «Ревизия…») и выходит.
        if CommandLine.arguments.contains("--audit-dict") {
            let entries = CorrectionStore.shared.allOrdered()
            let findings = DictionaryAudit.audit(entries)
            print("AUDIT: правил \(entries.count), с замечаниями \(findings.count)")
            for f in findings {
                print("  «\(f.entry.wrong)» → «\(f.entry.right)» — \(f.reason)"
                      + (f.neverUsed ? " · не применялось" : ""))
            }
            exit(0)
        }

        // Скрытый отладочный режим: `VoiceVoice --llm-test "текст"` — прогоняет текст
        // через LLMEditorService (загрузка/скачивание модели, промпт, гарды) и
        // завершается, минуя bootstrap. Сверка с прототипом `.mltools/eval_llm_editor.py`.
        if let idx = CommandLine.arguments.firstIndex(of: "--llm-test"),
           idx + 1 < CommandLine.arguments.count {
            let text = CommandLine.arguments[idx + 1]
            Task { @MainActor in
                // Дождаться скачивания модели (correct() его не ждёт — в жизни
                // диктовка не должна висеть минуты), иначе процесс выйдет раньше.
                LLMEditorService.shared.ensureLoaded()
                waiting: while true {
                    switch LLMEditorService.shared.state {
                    case .ready, .error: break waiting
                    case .downloading(let p): print("LLM-TEST downloading \(Int(p * 100))%")
                    default: break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                var out = ""
                for run in 1...2 {
                    let t0 = Date()
                    out = await LLMEditorService.shared.correct(text)
                    print("LLM-TEST run \(run): \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                }
                print("LLM-TEST IN : \(text)")
                print("LLM-TEST OUT: \(out)")
                exit(0)
            }
            return
        }

        // Скрытый отладочный режим: `VoiceVoice --update-test [install]` — проверка
        // обновления без кликов по меню и без алертов (с `install` — полный цикл:
        // скачивание DMG + установка в /Applications, БЕЗ перезапуска). Текущую
        // версию можно подменить: VOICEVOICE_FAKE_VERSION=1.0.0.
        if let idx = CommandLine.arguments.firstIndex(of: "--update-test") {
            let doInstall = idx + 1 < CommandLine.arguments.count
                && CommandLine.arguments[idx + 1] == "install"
            Task { @MainActor in
                do {
                    let release = try await AppUpdater.fetchLatestRelease()
                    let remote = AppUpdater.stripV(release.tag_name)
                    let current = AppUpdater.shared.currentVersion
                    let newer = AppUpdater.isNewer(remote, than: current)
                    let dmg = release.assets.first(where: { $0.name == "VoiceVoice.dmg" })
                    print("UPDATE-TEST current=\(current) latest=\(remote) newer=\(newer) dmg=\(dmg?.browser_download_url ?? "НЕТ")")
                    if doInstall, newer, let dmg, let url = URL(string: dmg.browser_download_url) {
                        try await AppUpdater.shared.downloadAndInstall(dmgURL: url, expectedVersion: remote)
                        print("UPDATE-TEST INSTALLED \(remote) → /Applications (перезапуск пропущен)")
                    }
                    exit(0)
                } catch {
                    print("UPDATE-TEST FAILED: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return
        }

        // Touch the database singleton early so migrations run.
        _ = Database.shared

        AppController.shared.bootstrap()

        if AppController.shared.onboardingNeeded {
            WindowOpener.openOnboarding()
        }
    }
}
