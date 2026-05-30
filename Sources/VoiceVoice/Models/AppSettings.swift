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
        case .capsLock: return "Caps Lock (удержание)"
        }
    }
}

/// Движок распознавания речи. WhisperKit — дефолт (Whisper на ANE). Parakeet —
/// опциональный быстрый движок на NVIDIA Parakeet TDT v3 через FluidAudio (модель
/// ~600 МБ качается только при выборе).
enum STTEngine: String, CaseIterable, Identifiable {
    case whisperKit = "whisperKit"
    case parakeet = "parakeet"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperKit: return "WhisperKit (Whisper, по умолчанию)"
        case .parakeet: return "Parakeet TDT v3 (быстрый, ~600 МБ)"
        }
    }
}

/// WhisperKit composes a folder-matching glob `*openai*{rawValue}/*` against
/// argmaxinc/whisperkit-coreml on HuggingFace, so `rawValue` must be the model
/// folder name WITHOUT the `openai_whisper-` prefix.
enum WhisperModelChoice: String, CaseIterable, Identifiable {
    case largeV3TurboQuantized = "large-v3-v20240930_turbo_632MB"
    case largeV3Turbo = "large-v3-v20240930_turbo"
    case largeV3 = "large-v3-v20240930"
    case medium = "medium"
    case small = "small"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largeV3TurboQuantized: return "large-v3-turbo, 4-bit (рекомендуется, ~632 МБ)"
        case .largeV3Turbo: return "large-v3-turbo (full precision, ~1.5 ГБ)"
        case .largeV3: return "large-v3 (макс. качество, без turbo, ~1.5 ГБ)"
        case .medium: return "medium (~770 МБ)"
        case .small: return "small (~480 МБ)"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("modelName") var modelName: String = WhisperModelChoice.largeV3TurboQuantized.rawValue
    /// Active speech-to-text engine (WhisperKit vs Parakeet). See `STTEngine`.
    @AppStorage("sttEngine") var sttEngineRaw: String = STTEngine.whisperKit.rawValue
    @AppStorage("hotkey") var hotkeyRaw: String = HotkeyKind.fn.rawValue
    @AppStorage("autoPaste") var autoPaste: Bool = true
    @AppStorage("alwaysKeepInClipboard") var alwaysKeepInClipboard: Bool = false
    @AppStorage("showResultHUD") var showResultHUD: Bool = true
    @AppStorage("language") var language: String = "ru"
    @AppStorage("onboardingDone") var onboardingDone: Bool = false
    @AppStorage("minConfirmedToApply") var minConfirmedToApply: Int = 1
    @AppStorage("punctuationPrompt") var punctuationPrompt: Bool = false
    /// Whether the dictionary applies fuzzy phrase matching (Levenshtein on normalized text).
    @AppStorage("fuzzyMatching") var fuzzyMatching: Bool = true
    /// Maximum allowed Levenshtein-distance / max-length ratio for a fuzzy match (0..1).
    @AppStorage("fuzzyThreshold") var fuzzyThreshold: Double = 0.25
    /// Persistent counter of dictionary substitutions ever applied (exact + fuzzy).
    @AppStorage("totalSubstitutions") var totalSubstitutions: Int = 0
    /// Of those, how many were fuzzy matches.
    @AppStorage("fuzzySubstitutions") var fuzzySubstitutions: Int = 0
    /// If true, the model is loaded at app launch (instant first Fn press, slower startup).
    /// If false (default), the model loads lazily on first interaction.
    @AppStorage("eagerLoad") var eagerLoad: Bool = false
    /// Unix timestamp of the last time WhisperKit finished `load()` successfully. Used by
    /// the Dashboard to communicate whether the *next* load will be quick (ANE-warm) or slow.
    @AppStorage("lastSuccessfulLoadAt") var lastSuccessfulLoadAt: Double = 0
    /// Whisper "model display id" of the last successful load — if it differs from the
    /// current `modelName`, the next load is "first time for this model" (slow).
    @AppStorage("lastSuccessfulModelId") var lastSuccessfulModelId: String = ""
    /// CoreAudio device UID for the chosen input mic. Empty string = follow system default.
    @AppStorage("inputDeviceUID") var inputDeviceUID: String = ""
    /// Run NumberNormalizer on the recognized text — collapses thousand-separator spaces
    /// and strips trailing periods after standalone digit sequences.
    @AppStorage("normalizeNumbers") var normalizeNumbers: Bool = true
    /// If true (default), after a verified paste we monitor the focused field for ~5 min
    /// and learn user edits into the dictionary as wrong→right corrections.
    @AppStorage("autoLearnCorrections") var autoLearnCorrections: Bool = true
    /// If true (default off), appends a context-appropriate emoji to the recognized text
    /// when a known trigger phrase is present (хаха → 😄, спасибо → 🙏, поздравляю → 🎉…).
    @AppStorage("autoEmoji") var autoEmoji: Bool = false
    /// If true (default OFF, opt-in), recognized speech is auto-formatted into
    /// markdown-ish lists: «первое… второе… третье…» → numbered list,
    /// «список покупок: a, b, c, d» → bullets, «новый абзац» → \n\n. See
    /// TextFormatter.swift for the full rule set. Off by default because it
    /// inserts newlines, which break single-line input fields.
    @AppStorage("autoFormat") var autoFormat: Bool = false
    /// If true (default ON), post-process Whisper's sentence-final punctuation
    /// with simple Russian rules: «ли»-particle and question-word starts force
    /// `?`; long sentences without question markers ending in `?` get `.`. See
    /// PunctuationFixer.swift.
    @AppStorage("fixPunctuation") var fixPunctuation: Bool = true
    /// If true (default ON), transcribe completed VAD chunks in the background WHILE
    /// recording, so on key-release only the short trailing tail remains to decode —
    /// long dictations feel near-instant. Output is identical to batch mode (same
    /// silence-cut boundaries); this only changes WHEN chunks are decoded. Turn off
    /// to revert to "transcribe everything on release".
    @AppStorage("eagerTranscription") var eagerTranscription: Bool = true
    /// User-editable list of Whisper hallucination phrases (one per line) that get
    /// dropped from recognized text when they appear as a whole sentence. Seeded from
    /// `Transcriber.defaultHallucinationBlocklistText`. Technical kill-tokens
    /// (DimaTorzok etc.) are handled separately in code and not exposed here.
    @AppStorage("hallucinationBlocklist") var hallucinationBlocklist: String = Transcriber.defaultHallucinationBlocklistText
    /// Master switch — when true, ALL HUDs / toasts / overlays are suppressed:
    /// recording mic, result HUD, learned-correction toast, ready toast, model-loading
    /// indicator. Useful for screencasts, presentations, focused work. Overrides the
    /// finer-grained `showResultHUD` toggle.
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
        STTEngine(rawValue: sttEngineRaw) ?? .whisperKit
    }

    private init() {
        if WhisperModelChoice(rawValue: modelName) == nil {
            modelName = WhisperModelChoice.largeV3TurboQuantized.rawValue
        }
        // Older versions defaulted minConfirmedToApply=2. Move existing users to 1
        // (apply right after first edit) — that's the new product behaviour.
        if !UserDefaults.standard.bool(forKey: "minConfirmedMigrated") {
            minConfirmedToApply = 1
            UserDefaults.standard.set(true, forKey: "minConfirmedMigrated")
        }
    }
}
