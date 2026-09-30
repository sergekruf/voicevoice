import Foundation
import SwiftUI

enum HotkeyKind: String, CaseIterable, Identifiable {
    case fn = "fn"
    case rightOption = "rightOption"
    case capsLock = "capsLock"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "Fn (удержание)"
        case .rightOption: return "Правый ⌥ Option (удержание)"
        case .capsLock: return "Caps Lock (нажать — старт, нажать — стоп)"
        }
    }
}

/// Движок распознавания речи. GigaAM — русский, лучшее качество (знаки и числа ставит
/// сам). Parakeet TDT v3 через FluidAudio — быстрый, 25 европейских языков. Модель
/// каждого качается при первом выборе. (WhisperKit убран в 1.1.8: медленнее, выдумывал
/// текст на тишине, по-русски хуже GigaAM, а другие языки закрывает Parakeet.)
enum STTEngine: String, CaseIterable, Identifiable {
    case parakeet = "parakeet"
    /// GigaAM-v3 e2e_rnnt — русскоязычная SOTA (пунктуация и нормализация встроены).
    case gigaAM = "gigaAM"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet TDT v3 (быстрый, 25 языков)"
        case .gigaAM: return "GigaAM v3 (русский, лучшее качество)"
        }
    }

    /// Имя для подписей в интерфейсе, где длинное не помещается.
    var shortName: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .gigaAM: return "GigaAM"
        }
    }
}

/// Клавиша быстрой правки: одиночное нажатие (без других клавиш) при выделенном
/// слове открывает окошко «как правильно» — замена в поле + пара в словарь.
enum QuickFixKey: String, CaseIterable, Identifiable {
    case rightCommand, leftControl, off

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .rightCommand: return "правый ⌘"
        case .leftControl: return "левый ⌃"
        case .off: return "выключено"
        }
    }
    /// keyCode в событии flagsChanged и флаг модификатора.
    var keyCode: Int? {
        switch self {
        case .rightCommand: return 54
        case .leftControl: return 59
        case .off: return nil
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightCommand: return .command
        case .leftControl, .off: return .control
        }
    }
}

/// Как часто проверять словарь правок автоматически.
enum DictionaryCheckSchedule: String, CaseIterable, Identifiable {
    case off, daily, weekly

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "не проверять"
        case .daily: return "раз в день"
        case .weekly: return "раз в неделю"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .daily: return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Active speech-to-text engine. Default is Parakeet since 1.1.1 (works for any of its
    /// 25 languages out of the box). See `STTEngine`. Existing users keep whatever they
    /// already selected — this default only applies to fresh installs.
    @AppStorage("sttEngine") var sttEngineRaw: String = STTEngine.parakeet.rawValue
    @AppStorage("hotkey") var hotkeyRaw: String = HotkeyKind.fn.rawValue
    @AppStorage("onboardingDone") var onboardingDone: Bool = false
    @AppStorage("minConfirmedToApply") var minConfirmedToApply: Int = 1
    /// Whether the dictionary applies fuzzy phrase matching (Levenshtein on normalized text).
    @AppStorage("fuzzyMatching") var fuzzyMatching: Bool = true
    /// Сохранять аудио диктовок локально для проверки качества распознавания (AudioArchive).
    /// Скрытая настройка разработчика, в интерфейсе нет: по умолчанию выключена —
    /// записи голоса (~50 МБ в день) не должны копиться у пользователей без спроса.
    /// Включить: `defaults write com.sergekruf.voicevoice keepDictationAudio -bool true`.
    @AppStorage("keepDictationAudio") var keepDictationAudio: Bool = false
    /// Быстрая правка выделенного слова (QuickFixService).
    @AppStorage("quickFixKey") var quickFixKeyRaw: String = QuickFixKey.rightCommand.rawValue
    var quickFixKey: QuickFixKey { QuickFixKey(rawValue: quickFixKeyRaw) ?? .rightCommand }
    /// Maximum allowed Levenshtein-distance / max-length ratio for a fuzzy match (0..1).
    /// 15%: одна буква в словах до 10 букв, две — в более длинных.
    @AppStorage("fuzzyThreshold") var fuzzyThreshold: Double = 0.15
    /// Persistent counter of dictionary substitutions ever applied (exact + fuzzy).
    @AppStorage("totalSubstitutions") var totalSubstitutions: Int = 0
    /// Of those, how many were fuzzy matches.
    @AppStorage("fuzzySubstitutions") var fuzzySubstitutions: Int = 0
    /// Unix timestamp of the last time the engine finished `load()` successfully.
    @AppStorage("lastSuccessfulLoadAt") var lastSuccessfulLoadAt: Double = 0
    /// Id of the model that loaded last (e.g. "gigaam-v3-e2e-rnnt").
    @AppStorage("lastSuccessfulModelId") var lastSuccessfulModelId: String = ""
    /// CoreAudio device UID for the chosen input mic. Empty string = follow system default.
    @AppStorage("inputDeviceUID") var inputDeviceUID: String = ""
    /// Run NumberNormalizer on the recognized text — collapses thousand-separator spaces
    /// and strips trailing periods after standalone digit sequences.
    @AppStorage("normalizeNumbers") var normalizeNumbers: Bool = true
    /// If true (default), after a verified paste we monitor the focused field for ~5 min
    /// and learn user edits into the dictionary as wrong→right corrections.
    @AppStorage("autoLearnCorrections") var autoLearnCorrections: Bool = true
    /// Автопроверка словаря правок: ревизия (что пора удалить) + разбор диктовок
    /// (что стоит добавить). Ничего не меняет сама — показывает тост с находками.
    @AppStorage("dictionaryCheckSchedule") var dictionaryCheckScheduleRaw: String =
        DictionaryCheckSchedule.weekly.rawValue
    /// Когда проверка отработала в последний раз (Unix-время).
    @AppStorage("lastDictionaryCheckAt") var lastDictionaryCheckAt: Double = 0

    var dictionaryCheckSchedule: DictionaryCheckSchedule {
        DictionaryCheckSchedule(rawValue: dictionaryCheckScheduleRaw) ?? .weekly
    }
    /// Приглушать системный звук (музыку/видео) на время записи, чтобы он не
    /// попадал в микрофон. Состояние вывода восстанавливается на отпускании клавиши.
    @AppStorage("muteSystemAudioOnRecord") var muteSystemAudioOnRecord: Bool = false
    /// Мгновенный старт записи: аудио-движок работает постоянно (кольцевой буфер
    /// ~1.5 с), нажатие клавиши стартует захват без задержки инициализации железа
    /// и прихватывает ~0.5 с ДО нажатия. Цена — постоянный индикатор микрофона macOS.
    @AppStorage("instantRecordStart") var instantRecordStart: Bool = true
    /// «Не отдавать системный вход Bluetooth-наушникам»: когда macOS при
    /// подключении BT-гарнитуры делает её микрофон системным входом, вернуть
    /// вход на встроенный (или выбранный в настройках не-BT) микрофон — иначе
    /// первое же приложение с микрофоном роняет звук наушников в HFP.
    @AppStorage("guardSystemInput") var guardSystemInput: Bool = false
    /// Master switch — when true, ALL HUDs / toasts / overlays are suppressed:
    /// recording mic, result HUD, learned-correction toast, ready toast, model-loading
    /// indicator. Useful for screencasts, presentations, focused work.
    @AppStorage("quietMode") var quietMode: Bool = false

    // ── Lifetime stats (incremented on every dictation, never trimmed). ─────────
    // The history table itself is capped at 200 rows, so HistoryStore.stats()
    // only sees the last 200 records — these counters give the Dashboard true
    // lifetime numbers. Seeded once on first launch after upgrade from the in-DB
    // counts (see AppController.migrateLifetimeStatsIfNeeded).
    @AppStorage("lifetimeRecordsCount")    var lifetimeRecordsCount: Int = 0
    @AppStorage("lifetimeCharactersCount") var lifetimeCharactersCount: Int = 0
    @AppStorage("lifetimeAudioSeconds")    var lifetimeAudioSeconds: Double = 0
    @AppStorage("lifetimeProcessingMs")    var lifetimeProcessingMs: Int = 0
    /// Unix timestamp of the very first ever transcription. 0 = none yet.
    @AppStorage("firstRecordAt")           var firstRecordAt: Double = 0
    /// Set to true after the one-time backfill from HistoryStore.stats() runs.
    @AppStorage("lifetimeStatsMigrated")   var lifetimeStatsMigrated: Bool = false

    var hotkey: HotkeyKind {
        HotkeyKind(rawValue: hotkeyRaw) ?? .fn
    }

    var sttEngine: STTEngine {
        STTEngine(rawValue: sttEngineRaw) ?? .parakeet
    }

    /// Ключи удалённых функций (WhisperKit, нейро-пунктуация RUPunct, Sage, LLM,
    /// старые правила знаков, давно убранные тумблеры) — вычищаются из настроек.
    static let obsoleteKeys = [
        "modelName", "language", "punctuationModel", "sageCorrector", "llmEditor",
        "llmIdleUnloadMinutes", "fixPunctuation", "eagerTranscription", "eagerLoad",
        "autoEmoji", "autoFormat", "keepClipboard", "alwaysKeepInClipboard", "punctuationPrompt",
        "gigaamBeamSize", "gigaamHotwords", "axFocusStats",
    ]

    private init() {
        // Пользователи Whisper переезжают на GigaAM (все они диктовали по-русски:
        // язык по умолчанию был «ru»), остальные языки — на Parakeet.
        let d = UserDefaults.standard
        if d.string(forKey: "sttEngine") == "whisperKit" {
            let lang = d.string(forKey: "language") ?? "ru"
            sttEngineRaw = lang == "ru" ? STTEngine.gigaAM.rawValue : STTEngine.parakeet.rawValue
        }
        for key in Self.obsoleteKeys where d.object(forKey: key) != nil { d.removeObject(forKey: key) }
        // Older versions defaulted minConfirmedToApply=2. Move existing users to 1
        // (apply right after first edit) — that's the new product behaviour.
        if !UserDefaults.standard.bool(forKey: "minConfirmedMigrated") {
            minConfirmedToApply = 1
            UserDefaults.standard.set(true, forKey: "minConfirmedMigrated")
        }
    }
}
