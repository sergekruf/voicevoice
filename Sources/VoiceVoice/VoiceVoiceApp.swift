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
    @ObservedObject private var parakeet = ParakeetTranscriber.shared
    @ObservedObject private var gigaam = GigaAMTranscriber.shared
    @ObservedObject private var settings = AppSettings.shared

    /// State of whichever engine is currently selected.
    private var engineState: Transcriber.ModelState {
        switch settings.sttEngine {
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

        // Скрытый отладочный режим: `VoiceVoice --transcribe-test a.wav b.wav …` —
        // прогоняет аудиофайлы через GigaAM (или Parakeet при VOICEVOICE_ENGINE=parakeet) —
        // нарезка, стыки, склейка — без микрофона.
        if let idx = CommandLine.arguments.firstIndex(of: "--transcribe-test"),
           idx + 1 < CommandLine.arguments.count {
            let paths = Array(CommandLine.arguments[(idx + 1)...])
            Task { @MainActor in
                for path in paths {
                    do {
                        let audio = try AudioFileDecoder.decode(url: URL(fileURLWithPath: path))
                        let out = ProcessInfo.processInfo.environment["VOICEVOICE_ENGINE"] == "parakeet"
                            ? await ParakeetTranscriber.shared.transcribe(audio: audio)
                            : await GigaAMTranscriber.shared.transcribe(audio: audio)
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
                // Знака на стыке нет, заглавная — артефакт начала окна: в контексте строчная.
                ("Можно сильно всё это дело", "Прокачать по удобству и функционалу",
                 "получить от тебя обратную связь, то можно сильно всё это дело прокачать по удобству",
                 .continuation(left: "Можно сильно всё это дело", right: "прокачать по удобству и функционалу",
                               removedQuestion: false)),
                // Знака нет, но это имя — в контексте тоже заглавная, регистр остаётся.
                ("Вчера долго говорил с", "Сергеем про поставку",
                 "вчера долго говорил с Сергеем про поставку и сроки",
                 .continuation(left: "Вчера долго говорил с", right: "Сергеем про поставку", removedQuestion: false)),
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

        // Скрытый отладочный режим: `VoiceVoice --question-test` — потерянный «?»
        // (PunctuationFixer.restoreQuestionMarks) на контрольных фразах; с `history` —
        // ещё и все места в истории, где шаг поставил бы «?».
        if let idx = CommandLine.arguments.firstIndex(of: "--question-test") {
            let cases: [(String, String)] = [
                // Вопросы из истории диктовок.
                ("Ребята сфоткали эти две модели. Что-то ещё было или это всё",
                 "Ребята сфоткали эти две модели. Что-то ещё было или это всё?"),
                ("А ты можешь сделать не одним файлом, а тремя отдельными файлами и каждый формата A4",
                 "А ты можешь сделать не одним файлом, а тремя отдельными файлами и каждый формата A4?"),
                ("А ты можешь на этом баннере просто логотип сделать красным.",
                 "А ты можешь на этом баннере просто логотип сделать красным?"),
                ("Так ли это? Какие модели мы можем изготовить. Я их добавлю на баннер.",
                 "Так ли это? Какие модели мы можем изготовить? Я их добавлю на баннер."),
                ("можем ли мы данные позиции продать немножко в убыток", "можем ли мы данные позиции продать немножко в убыток?"),
                ("Ты можешь взять за основу этот постер и сделать 3 варианта,",
                 "Ты можешь взять за основу этот постер и сделать 3 варианта?"),
                // Вопросы, которых нет в истории.
                ("Сколько коробок осталось на складе", "Сколько коробок осталось на складе?"),
                ("Подскажи, где найти отчёт по продажам.", "Подскажи, где найти отчёт по продажам?"),
                ("Мы успеем отгрузить до конца недели или нет", "Мы успеем отгрузить до конца недели или нет?"),
                ("Сможешь посмотреть макет до вечера", "Сможешь посмотреть макет до вечера?"),
                ("Отправил счёт, верно", "Отправил счёт, верно?"),
                // Утверждения с «вопросительными» словами — не трогать; в конце точка.
                ("Нужно обновить логотип", "Нужно обновить логотип."),
                ("Можно сделать PNG.", "Можно сделать PNG."),
                ("Когда придёт машина, позвони мне.", "Когда придёт машина, позвони мне."),
                ("Как только закончишь, отправь отчёт", "Как только закончишь, отправь отчёт."),
                ("Как в прошлый раз, нет никакой детализации.", "Как в прошлый раз, нет никакой детализации."),
                ("Что-то здесь не так, нужно доработать", "Что-то здесь не так, нужно доработать."),
                ("Я не знаю, будет ли он завтра.", "Я не знаю, будет ли он завтра."),
                ("Вряд ли успеем до пятницы.", "Вряд ли успеем до пятницы."),
                ("Ты, кстати, можешь просто бота просить отслеживать слоты.",
                 "Ты, кстати, можешь просто бота просить отслеживать слоты."),
                ("Можешь не торопиться, это не срочно.", "Можешь не торопиться, это не срочно."),
                ("Сколько бы ни стоило, берём.", "Сколько бы ни стоило, берём."),
                ("Что касается цен, их обновим завтра.", "Что касается цен, их обновим завтра."),
                // Уже стоящие знаки не трогаются.
                ("Ты придёшь завтра? Отлично!", "Ты придёшь завтра? Отлично!"),
                ("Ну и дела…", "Ну и дела…"),
            ]
            var ok = 0
            for (input, expected) in cases {
                let got = PunctuationFixer.restoreQuestionMarks(input)
                if got == expected { ok += 1 }
                print("\(got == expected ? "PASS" : "FAIL")  \(got)\(got == expected ? "" : "\n      ожидалось: \(expected)")")
            }
            print("\nверно: \(ok)/\(cases.count)")
            if idx + 1 < CommandLine.arguments.count, CommandLine.arguments[idx + 1] == "history" {
                print("\n=== история: где шаг поставил бы «?» ===")
                for r in HistoryStore.shared.recent(limit: 1000) {
                    let fixed = PunctuationFixer.restoreQuestionMarks(r.finalText)
                    let before = r.finalText.filter { $0 == "?" }.count, after = fixed.filter { $0 == "?" }.count
                    if after > before { print("  \(fixed)") }
                }
            }
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
                ("Если есть пожелание, какое-то хотелки", "Если есть пожелание и какие-то хотелки",
                 "какое-то → и какие-то (без запятой)"),
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
                       ("сегодняшние", "сегодняшнего"), ("аппаратном", "платном"),
                       ("какое-то", "и какие-то"), (", какое-то", "и какие-то")]
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

        // Скрытый отладочный режим: `VoiceVoice --dict-sim` — что словарь правок делает
        // с текстами из истории: точные замены и отдельно — добавленные нечётким сравнением.
        if CommandLine.arguments.contains("--dict-sim") {
            for r in HistoryStore.shared.recent(limit: 1000).reversed() {
                let exact = CorrectionApplier.shared.apply(to: r.rawText, fuzzy: false)
                let full = CorrectionApplier.shared.apply(to: r.rawText, fuzzy: true)
                for s in exact.substitutions { print("ТОЧНО  «\(s.wrong)» → «\(s.right)»") }
                for s in full.substitutions where s.fuzzy {
                    let words = full.text.split(separator: " ")
                    let pos = min(max(0, s.positionInOutput / 2), words.count)
                    let ctx = words[max(0, pos - 3)..<min(words.count, pos + 3)].joined(separator: " ")
                    print("НЕЧЁТКО по «\(s.wrong)» → «\(s.right)»   …\(ctx)…")
                    print("        было: \(r.rawText.prefix(160))")
                }
            }
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
