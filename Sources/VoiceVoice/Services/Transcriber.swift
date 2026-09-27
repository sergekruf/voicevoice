import Foundation
import Accelerate

/// Общая часть всех движков распознавания: состояние модели, нарезка длинной записи
/// на куски по паузам, склейка текстов кусков, сверка стыков и блоклист галлюцинаций.
/// (Раньше здесь же жил движок WhisperKit; его убрали — остались GigaAM и Parakeet.)
@MainActor
enum Transcriber {
    enum ModelState: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case loading
        case ready
        case error(String)
    }

    /// Детектор речи по громкости — тот же алгоритм, что EnergyVAD из WhisperKit, на
    /// котором настраивались пороги нарезки: RMS каждого кадра 0,1 с против порога 0,02.
    struct EnergyVAD {
        let frameLengthSamples = 1600
        let energyThreshold: Float = 0.02

        func voiceActivity(in waveform: [Float]) -> [Bool] {
            let count = Int((Double(waveform.count) / Double(frameLengthSamples)).rounded(.up))
            return (0..<count).map { i in
                let start = i * frameLengthSamples
                let end = min(start + frameLengthSamples, waveform.count)
                var rms: Float = 0
                waveform.withUnsafeBufferPointer { buf in
                    vDSP_rmsqv(buf.baseAddress! + start, 1, &rms, vDSP_Length(end - start))
                }
                return rms > energyThreshold
            }
        }

        func voiceActivityIndexToAudioSampleIndex(_ index: Int) -> Int { index * frameLengthSamples }

        /// Самый длинный непрерывный участок тишины (false) в разметке.
        func findLongestSilence(in vad: [Bool]) -> (startIndex: Int, endIndex: Int)? {
            var best: (startIndex: Int, endIndex: Int)?
            var i = 0
            while i < vad.count {
                if vad[i] { i += 1; continue }
                var j = i
                while j < vad.count, !vad[j] { j += 1 }
                if j - i > (best.map { $0.endIndex - $0.startIndex } ?? 0) { best = (i, j) }
                i = j
            }
            return best
        }
    }

    // MARK: - Pre-chunking

    /// Hard cap per chunk. 12 секунд ≈ 180-200 токенов на плотной русской речи —
    /// безопасный запас от потолка декодера 223 (см. комментарий выше).
    nonisolated private static let maxChunkSamples: Int = 12 * Int(AudioRecorder.targetSampleRate)
    /// Не режем, если аудио помещается в один чанк (плюс небольшой допуск, чтобы
    /// 12.5-секундную запись не дробить на 12 + 0.5).
    private static let chunkCutoffSamples: Int = 13 * Int(AudioRecorder.targetSampleRate)
    /// Окно поиска тишины вокруг целевой границы (±2 секунды).
    private static let silenceSearchWindowSamples: Int = 2 * Int(AudioRecorder.targetSampleRate)
    /// Насколько НАЗАД от целевой границы искать НАСТОЯЩУЮ паузу (≥0.5 с). Рез по
    /// настоящей паузе — корректная граница предложения (точка и заглавная от движка
    /// легитимны), а вынужденный рез посреди фразы рождает ложную заглавную на стыке
    /// («…за каждую | Штуку»), которую склейка умеет снимать только у служебных слов.
    /// Лучше кусок на несколько секунд короче, чем рез внутри предложения.
    private static let pauseLookbackWindowSamples: Int = 5 * Int(AudioRecorder.targetSampleRate)
    /// Минимальная длина тишины (во VAD-фреймах по 0.1 с), чтобы принять её как точку
    /// реза. EnergyVAD ловит и одиночные 100-мс провалы энергии — это часто пауза
    /// ВНУТРИ слова (взрывные согласные, придыхание), рез по ней обрезает звук. Требуем
    /// ≥ 3 фреймов (~300 мс) — настоящая граница между словами/фразами. Если такой
    /// тишины в окне нет, режем по `maxChunkSamples` (как раньше). Ноль новых
    /// зависимостей; нейро-VAD (Silero) при необходимости — отдельный шаг.
    private static let minSilenceFrames = 3
    /// Порог «настоящей границы предложения»: пауза ≥0.5 с. Более короткая тишина
    /// (0.3–0.5 с) — годная точка реза, но слишком часто оказывается заминкой
    /// ВНУТРИ фразы или растянутым словом («скину…ть») — на таком стыке ложная
    /// точка/заглавная должны убираться склейкой, а не сохраняться.
    private static let realPauseMinFrames = 5

    /// Делит аудио на куски ≤ `maxChunkSamples`, стараясь резать по самой длинной
    /// тишине в окне `[target ± silenceSearchWindow]`. Если тишины нет — режет
    /// тупо по `maxChunkSamples` (хуже, но всё равно лучше потерянного хвоста).
    ///
    /// Internal — переиспользуется ParakeetTranscriber: у Parakeet своя причина резать
    /// (FluidAudio даёт пунктуацию/заглавные только на одном окне ≤ 15 с = 240_000
    /// сэмплов; длиннее → скользящее окно без пунктуации). Наш максимум реза =
    /// `maxChunkSamples`(12 с) + `silenceSearchWindow`(2 с) = 14 с < 15 с — безопасно
    /// держит каждый кусок в «однооконном» пунктуационном пути обоих движков.
    /// Один кусок аудио + признак того, что рез ПОСЛЕ него пришёлся на настоящую паузу
    /// (≥ minSilenceFrames). На таком стыке движок ставит границу предложения корректно;
    /// на вынужденном резе (`realPauseAfter == false`) точка/заглавная ложные — склейка
    /// их уберёт (см. `joinChunkTexts`). Последний кусок всегда `realPauseAfter == true`.
    struct AudioChunk { let samples: [Float]; let realPauseAfter: Bool }

    /// `windowSeconds` — сколько движок принимает за один проход: 15 с у Parakeet и
    /// Whisper-пути, у GigaAM — окно сконвертированной модели (до 25 с). Цель реза —
    /// окно минус 3 с, запас на поиск паузы вперёд — 2 с, так что кусок всегда влезает.
    static func chunkBySilence(_ audio: [Float], windowSeconds: Int = 15) -> [AudioChunk] {
        let sr = Int(AudioRecorder.targetSampleRate)
        let maxChunk = (windowSeconds - 3) * sr      // 12 с при окне 15 с — как раньше
        let cutoff = (windowSeconds - 2) * sr         // 13 с при окне 15 с
        if audio.count <= cutoff { return [AudioChunk(samples: audio, realPauseAfter: true)] }
        let vad = EnergyVAD()  // sampleRate=16000, frameLengthSamples=1600 (0.1 с)
        var result: [AudioChunk] = []
        var cursor = 0
        while cursor < audio.count {
            let remaining = audio.count - cursor
            if remaining <= cutoff {
                result.append(AudioChunk(samples: Array(audio[cursor..<audio.count]), realPauseAfter: true))
                break
            }
            let (cutAt, realPause) = findSilenceCut(in: audio, from: cursor, upTo: audio.count, vad: vad,
                                                    maxChunk: maxChunk)
            result.append(AudioChunk(samples: Array(audio[cursor..<cutAt]), realPauseAfter: realPause))
            cursor = cutAt
        }
        return result
    }

    /// Находит точку реза для чанка, начинающегося на `from`. Приоритет:
    ///   1) ПОСЛЕДНЯЯ настоящая пауза (≥ realPauseMinFrames) в широком окне
    ///      `[target − pauseLookback, target + silenceSearchWindow]` — корректная
    ///      граница предложения, `realPause = true`. Берём последнюю, а не самую
    ///      длинную: любая пауза ≥0.5 с — легитимная граница, а поздний рез =
    ///      длиннее куски и меньше стыков;
    ///   2) иначе — самая длинная короткая тишина (≥ minSilenceFrames) в узком окне
    ///      `±silenceSearchWindow` — годная точка реза, но граница ложная;
    ///   3) иначе — САМАЯ ТИХАЯ точка узкого окна (микропауза между словами), а не
    ///      слепой индекс `target`.
    /// На ложной границе (2 и 3) склейка потом уберёт ложную точку/заглавную.
    /// Гарантирует `from < cut <= limit`.
    static func findSilenceCut(in audio: [Float], from cursor: Int, upTo limit: Int, vad: EnergyVAD,
                               maxChunk: Int = maxChunkSamples) -> (cut: Int, realPause: Bool) {
        let target = cursor + maxChunk

        // Фаза 1: настоящая пауза в широком окне (с запасом назад от цели).
        let wideStart = max(target - pauseLookbackWindowSamples, cursor + 1)
        let wideEnd = min(target + silenceSearchWindowSamples, limit)
        if wideEnd > wideStart {
            let window = Array(audio[wideStart..<wideEnd])
            let vadResult = vad.voiceActivity(in: window)
            if let run = lastSilenceRun(in: vadResult, minFrames: realPauseMinFrames) {
                let mid = run.startIndex + (run.endIndex - run.startIndex) / 2
                let cutAt = wideStart + vad.voiceActivityIndexToAudioSampleIndex(mid)
                return (min(max(cutAt, cursor + 1), limit), true)
            }
        }

        // Фаза 2: настоящей паузы нет — прежнее поведение в узком окне вокруг цели.
        let searchStart = max(target - silenceSearchWindowSamples, cursor + 1)
        let searchEnd = min(target + silenceSearchWindowSamples, limit)
        var cutAt = target
        if searchEnd > searchStart {
            let window = Array(audio[searchStart..<searchEnd])
            let vadResult = vad.voiceActivity(in: window)
            if let silence = vad.findLongestSilence(in: vadResult),
               silence.endIndex - silence.startIndex >= minSilenceFrames {
                // Тишина 0.3–0.5 с → режем по её середине (макс. отступ от речи);
                // паузы ≥0.5 с сюда не доходят — их забрала фаза 1.
                let frames = silence.endIndex - silence.startIndex
                let silenceMid = silence.startIndex + frames / 2
                cutAt = searchStart + vad.voiceActivityIndexToAudioSampleIndex(silenceMid)
            } else {
                cutAt = searchStart + lowestEnergyOffset(in: window)
            }
        }
        return (min(max(cutAt, cursor + 1), limit), false)
    }

    /// Последний непрерывный участок тишины длиной ≥ `minFrames` во VAD-разметке
    /// (true = речь). Участок, упирающийся в конец окна, тоже считается.
    private static func lastSilenceRun(in vadResult: [Bool], minFrames: Int) -> (startIndex: Int, endIndex: Int)? {
        var best: (startIndex: Int, endIndex: Int)? = nil
        var runStart: Int? = nil
        for (i, isVoice) in vadResult.enumerated() {
            if !isVoice {
                if runStart == nil { runStart = i }
            } else if let s = runStart {
                if i - s >= minFrames { best = (s, i) }
                runStart = nil
            }
        }
        if let s = runStart, vadResult.count - s >= minFrames {
            best = (s, vadResult.count)
        }
        return best
    }

    /// Возвращает offset (в сэмплах от начала `window`) центра кадра 0.1 с с
    /// наименьшей энергией — самая тихая точка окна, лучший кандидат на рез, когда
    /// явной паузы нет.
    private static func lowestEnergyOffset(in window: [Float]) -> Int {
        let frame = 1600                       // 0.1 с при 16 кГц
        guard window.count > frame else { return window.count / 2 }
        var minEnergy = Float.greatestFiniteMagnitude
        var bestCenter = window.count / 2
        var i = 0
        while i < window.count {
            let end = Swift.min(i + frame, window.count)
            var sum: Float = 0
            var j = i
            while j < end { sum += window[j] * window[j]; j += 1 }
            let energy = sum / Float(end - i)
            if energy < minEnergy {
                minEnergy = energy
                bestCenter = i + (end - i) / 2
            }
            i += frame
        }
        return bestCenter
    }

    // MARK: - Smart join across chunk boundaries

    /// Слова, которые обычно стоят со строчной буквы внутри предложения. Если кусок
    /// после ВЫНУЖДЕННОГО реза начинается с такого слова с заглавной — это ложная
    /// заглавная (движок принял стык за начало предложения), приводим к строчной.
    /// Имена собственные сюда НЕ входят — их регистр не трогаем.
    private static let lowercaseLeadWords: Set<String> = [
        "и", "а", "но", "что", "чтобы", "потому", "поэтому", "для", "в", "во", "на", "с",
        "со", "по", "к", "о", "об", "из", "от", "до", "при", "за", "под", "над", "это",
        "как", "когда", "если", "то", "же", "бы", "ли", "или", "да", "тоже", "также",
        "хотя", "пока", "раз", "ведь", "чем", "где", "куда", "откуда", "зато", "причем",
        "который", "которая", "которое", "которые", "которых", "которым", "которой",
        "которую", "которого", "котором", "которыми", "которому",
        "его", "ее", "их", "там", "тут", "здесь", "потом", "затем", "значит", "поэтому",
        "чтоб", "ну", "вот", "так",
        // Местоимения, предлоги, наречия, частицы, числительные и связки —
        // именем собственным не бывают, понижать безопасно.
        "я", "ты", "мы", "вы", "он", "она", "оно", "они",
        "меня", "тебя", "нас", "вас", "мне", "тебе", "нам", "вам",
        "ему", "ей", "им", "ими", "себя", "себе",
        "этот", "эта", "эти", "этим", "этом", "этих", "тот", "та", "те", "том", "тем",
        "все", "всех", "всем", "вся", "всю", "всего",
        "у", "без", "про", "через", "перед", "после", "между", "среди",
        "возле", "около", "кроме", "вместо", "против",
        "уже", "еще", "только", "даже", "просто", "сейчас", "теперь", "тогда",
        "снова", "опять", "очень", "вообще", "кстати", "наверное", "например",
        "однако", "либо", "пусть", "именно", "почти", "сразу", "дальше", "далее",
        "один", "одна", "одно", "два", "две", "три", "четыре", "пять",
        "шесть", "семь", "восемь", "девять", "десять", "оба", "обе",
        "будет", "было", "были", "был", "есть", "нет", "надо", "нужно", "можно",
    ]

    /// Склеивает куски с учётом флага `realPauseAfter`:
    ///   • после НАСТОЯЩЕЙ паузы — оставляем как отдельные предложения (точка + заглавная);
    ///   • после ВЫНУЖДЕННОГО реза (середина предложения) — убираем ложную точку у
    ///     предыдущего куска и ложную заглавную у следующего (если это служебное слово),
    ///     склеивая в одно предложение.
    static func joinChunkTexts(_ items: [(text: String, realPauseAfter: Bool)]) -> String {
        var out = ""
        for (i, item) in items.enumerated() {
            var t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Кусок, начавшийся с обрезанного резом слова, движки помечают мусорной
            // пунктуацией в начале («..ть», «, слово») — вычищаем ведущие знаки.
            while let f = t.first, ".,;:…".contains(f) { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if out.isEmpty { out = t; continue }
            if items[i - 1].realPauseAfter {
                // Настоящая пауза. Два симметричных артефакта стыка:
                //  • терминатор есть, а следующий кусок со строчной («…текст. повторные…»)
                //    → поднимаем регистр;
                //  • терминатора НЕТ (движок понял, что предложение продолжается:
                //    «…связь от | У других…»), а следующий кусок начат с заглавной —
                //    это «начало высказывания» декодера, а не граница → понижаем
                //    служебное слово (список консервативный, имена не трогаем).
                if let last = out.last, ".!?…".contains(last) {
                    out += " " + uppercasedLead(t)
                } else {
                    out += " " + lowercasedLeadIfFunction(t)
                }
            } else {
                out = stripTrailingSentenceTerminator(out)
                out += " " + lowercasedLeadIfFunction(t)
            }
        }
        return out
    }

    private static func stripTrailingSentenceTerminator(_ s: String) -> String {
        var t = s
        while let last = t.last, last == "." || last == "…" { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func uppercasedLead(_ s: String) -> String {
        guard let first = s.first, first.isLowercase else { return s }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private static func lowercasedLeadIfFunction(_ s: String) -> String {
        guard let first = s.first, first.isUppercase else { return s }
        let word = String(s.prefix(while: { $0.isLetter }))
            .lowercased().replacingOccurrences(of: "ё", with: "е")
        guard lowercaseLeadWords.contains(word) else { return s }
        return s.prefix(1).lowercased() + s.dropFirst()
    }

    // MARK: - Стык кусков: сверка с контекстным прогоном

    /// Вердикт по стыку двух кусков: левый кончается знаком конца предложения, либо знака
    /// нет, а правый начат с заглавной (тогда `.continuation` просто сверяет регистр).
    /// Контекстный прогон делает движок (`GigaAMTranscriber.reconcileSeams`), здесь —
    /// текстовая часть: найти стык в контексте и перенести решение о знаке.
    enum SeamVerdict: Equatable {
        /// Пара слов у стыка не нашлась в контексте однозначно — не трогаем.
        case unmatched
        /// В контексте на стыке тоже граница предложения — знак настоящий.
        case boundary
        /// В контексте знака нет: убираем его (запятую из контекста сохраняем),
        /// регистр первого слова справа — как в контексте.
        case continuation(left: String, right: String, removedQuestion: Bool)
    }

    nonisolated private static let seamTerminators: Set<Character> = [".", "?", "!", "…"]

    private struct SeamWord {
        let core: String
        let trailing: String
        let startsLowercase: Bool
    }

    nonisolated private static func seamWords(_ s: String) -> [SeamWord] {
        s.split(whereSeparator: { $0.isWhitespace }).compactMap { token -> SeamWord? in
            let core = String(token.filter { $0.isLetter || $0.isNumber })
                .lowercased().replacingOccurrences(of: "ё", with: "е")
            guard !core.isEmpty else { return nil }
            let trailing = String(token.reversed().prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())
            let startsLowercase = token.first(where: { $0.isLetter })?.isLowercase ?? false
            return SeamWord(core: core, trailing: trailing, startsLowercase: startsLowercase)
        }
    }

    /// Созвучие не дальше 30% длины и не для коротких слов («в» / «во» — не созвучие).
    nonisolated private static func isSimilarSeamWord(_ a: String, _ b: String) -> Bool {
        guard min(a.count, b.count) >= 4 else { return false }
        return a.levenshteinDistance(to: b) * 10 <= max(a.count, b.count) * 3
    }

    nonisolated static func endsWithSentenceTerminator(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return seamTerminators.contains(last)
    }

    nonisolated static func reconcileSeam(left: String, right: String, context: String) -> SeamVerdict {
        let l = seamWords(left), r = seamWords(right), c = seamWords(context)
        guard let l1 = l.last, let r1 = r.first, c.count >= 3 else { return .unmatched }
        let l2 = l.count >= 2 ? l[l.count - 2].core : nil
        let r2 = r.count >= 2 ? r[1].core : nil
        // Пара «последнее слово слева — первое справа» подряд плюс хотя бы один сосед:
        // одна короткая пара («офис | в») совпадает и случайно. Второй прогон может
        // распознать слово у стыка чуть иначе (бренды: «Wildberres» / «Wildberrieces») —
        // тогда одно из двух допускается созвучным, но совпасть должны оба соседа.
        var matches: [Int] = []
        for k in 0..<(c.count - 1) {
            let leftExact = c[k].core == l1.core, rightExact = c[k + 1].core == r1.core
            guard leftExact || rightExact else { continue }
            let leftNeighbor = k > 0 && l2 != nil && c[k - 1].core == l2
            let rightNeighbor = k + 2 < c.count && r2 != nil && c[k + 2].core == r2
            if leftExact && rightExact {
                if leftNeighbor || rightNeighbor { matches.append(k) }
            } else if leftNeighbor && rightNeighbor,
                      isSimilarSeamWord(leftExact ? c[k + 1].core : c[k].core,
                                        leftExact ? r1.core : l1.core) {
                matches.append(k)
            }
        }
        guard matches.count == 1, let k = matches.first else { return .unmatched }
        if c[k].trailing.contains(where: { seamTerminators.contains($0) }) { return .boundary }

        var newLeft = left
        var removed = ""
        while let last = newLeft.last, seamTerminators.contains(last) || last.isWhitespace {
            removed.append(last)
            newLeft.removeLast()
        }
        if let mark = c[k].trailing.first(where: { ",;:".contains($0) }) { newLeft.append(mark) }
        var newRight = right
        if c[k + 1].startsLowercase, let idx = newRight.firstIndex(where: { $0.isLetter }),
           newRight[idx].isUppercase {
            newRight.replaceSubrange(idx...idx, with: newRight[idx].lowercased())
        }
        return .continuation(left: newLeft, right: newRight, removedQuestion: removed.contains("?"))
    }

    /// Убранный на стыке «?» не теряем: вопрос продолжился в следующем куске, и знак
    /// встаёт в конец этого предложения — на место первой точки или многоточия
    /// («…шли напрямую.» → «…шли напрямую?»). Если первым встретился «!» или «?» —
    /// предложение уже закончено своим знаком. `done == false` — знака в тексте нет,
    /// перенос продолжается в следующий кусок.
    nonisolated static func moveQuestionMark(into text: String) -> (text: String, done: Bool) {
        var chars = Array(text)
        var i = 1
        while i < chars.count {
            guard seamTerminators.contains(chars[i]), !chars[i - 1].isWhitespace else { i += 1; continue }
            var j = i
            while j < chars.count, seamTerminators.contains(chars[j]) { j += 1 }
            // Точка внутри «ozon.ru», «10.5» — не конец предложения.
            guard j == chars.count || chars[j].isWhitespace else { i = j; continue }
            if chars[i..<j].contains("?") || chars[i..<j].contains("!") { return (text, true) }
            chars.replaceSubrange(i..<j, with: ["?"])
            return (String(chars), true)
        }
        return (text, false)
    }

    static func cleanup(_ s: String) -> String {
        // Trim and collapse leading/trailing whitespace; Whisper sometimes adds a leading space.
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse multiple spaces.
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t
    }

    // MARK: - Hallucination blocklist

    /// Whisper заучил титры с YouTube из несанированных обучающих данных и на
    /// тишине/шуме/паузах уверенно выдаёт самую вероятную конфабуляцию. В русском
    /// это узнаваемые фразы-«титры». VAD-обрезка тишины убирает большинство
    /// триггеров, но детерминированный блоклист — это 100%-надёжный добивающий
    /// слой. Сравнение пословное по ЦЕЛОМУ предложению (а не подстроке), чтобы не
    /// съесть настоящую речь. Новые артефакты можно добавлять сюда из логов.
    ///
    /// Встроенный список фраз-«титров» (одна на строку). Редактор в настройках убран
    /// как невостребованный — новые артефакты добавляются сюда из логов. Технические
    /// kill-токены (DimaTorzok и т.п.) живут отдельно в `hallucinationSubstrings`.
    nonisolated static let defaultHallucinationBlocklistText = """
    Продолжение следует
    Спасибо за просмотр
    Подписывайтесь на канал
    Подписывайтесь на наш канал
    Ставьте лайки и подписывайтесь
    """

    /// Распаршенный дефолтный блоклист (единожды).
    nonisolated static let defaultBlocklist: Set<String> = parseBlocklist(defaultHallucinationBlocklistText)

    /// Парсит многострочный список в нормализованное множество для сравнения.
    nonisolated static func parseBlocklist(_ raw: String) -> Set<String> {
        var set = Set<String>()
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let norm = normalizeForBlocklist(String(line))
            if !norm.isEmpty { set.insert(norm) }
        }
        return set
    }

    /// Токены, которые НИКОГДА не встречаются в осмысленной русской диктовке —
    /// если предложение их содержит, оно целиком артефакт. В отличие от
    /// `hallucinationSentences`, матчатся как подстрока.
    private static let hallucinationSubstrings: [String] = [
        "dimatorzok",
        "amara.org",
        "subtitles by",
        "редактор субтитров",
        "корректор а.",
    ]

    /// Удаляет из текста предложения, целиком совпадающие с известными
    /// галлюцинациями Whisper. Безопасно для настоящей речи: дропается только
    /// предложение, нормализованная форма которого равна записи блоклиста или
    /// содержит «kill-token» вроде `dimatorzok`. `sentenceBlocklist` — нормализованное
    /// множество фраз (из настроек пользователя).
    static func stripHallucinations(_ text: String, sentenceBlocklist: Set<String>) -> String {
        guard !text.isEmpty else { return text }
        let sentences = splitSentencesKeepingTrailing(text)
        var kept: [String] = []
        for sent in sentences {
            let norm = normalizeForBlocklist(sent)
            if norm.isEmpty {
                kept.append(sent)
                continue
            }
            if sentenceBlocklist.contains(norm) {
                DebugLog.log("Blocklist: dropped sentence \"\(norm.prefix(60))\"")
                continue
            }
            if hallucinationSubstrings.contains(where: { norm.contains($0) }) {
                DebugLog.log("Blocklist: dropped (substring) \"\(norm.prefix(60))\"")
                continue
            }
            kept.append(sent)
        }
        return kept.joined()
    }

    nonisolated private static func normalizeForBlocklist(_ s: String) -> String {
        var n = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        n = n.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r.,!?…—–-«»\"'()"))
        while n.contains("  ") { n = n.replacingOccurrences(of: "  ", with: " ") }
        return n
    }

    /// Делит текст на предложения, сохраняя хвостовой разделитель на каждом куске,
    /// так что `.joined()` воспроизводит исходный текст (минус выкинутые).
    private static func splitSentencesKeepingTrailing(_ s: String) -> [String] {
        let ns = s as NSString
        let regex = try! NSRegularExpression(pattern: #"(?<=[\.\!\?…])\s+"#, options: [])
        let matches = regex.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return [s] }
        var result: [String] = []
        var cursor = 0
        for m in matches {
            let len = m.range.location - cursor
            let sent = ns.substring(with: NSRange(location: cursor, length: len))
            let sep = ns.substring(with: m.range)
            result.append(sent + sep)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { result.append(ns.substring(from: cursor)) }
        return result
    }
}
