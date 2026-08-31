import Foundation
import AppKit

/// Проверка обновлений и самообновление через GitHub Releases.
///
/// Схема: `/releases/latest` → сравнение tag_name с CFBundleShortVersionString →
/// скачивание ассета `VoiceVoice.dmg` (с прогрессом) → `hdiutil attach` →
/// проверка версии внутри образа → подмена бандла в /Applications → перезапуск.
///
/// Почему это работает без Sparkle и без повторного Gatekeeper-карантина:
///   • новая копия подписана тем же self-signed "VoiceVoiceDev" — designated
///     requirement совпадает, TCC-разрешения (микрофон/Accessibility) сохраняются;
///   • файлы, скачанные URLSession, карантин не получают (в Info.plist нет
///     LSFileQuarantineEnabled), так что «Открыть всё равно» заново не понадобится;
///   • бандл РАБОТАЮЩЕГО приложения можно подменять (процесс держит inode) —
///     ровно так обновления ставились вручную через ditto всё это время.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    private init() {}

    enum State: Equatable {
        case idle
        case checking
        case downloading(progress: Double)
        case installing
    }

    @Published private(set) var state: State = .idle

    private static let apiLatest = "https://api.github.com/repos/sergekruf/voicevoice/releases/latest"
    private static let dmgAssetName = "VoiceVoice.dmg"
    private static let installPath = "/Applications/VoiceVoice.app"

    private struct Err: LocalizedError { let m: String; var errorDescription: String? { m } }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let assets: [Asset]
    }

    /// Текущая версия; переопределяется VOICEVOICE_FAKE_VERSION (для отладки
    /// полного цикла обновления без публикации нового релиза).
    var currentVersion: String {
        if let fake = ProcessInfo.processInfo.environment["VOICEVOICE_FAKE_VERSION"], !fake.isEmpty {
            return fake
        }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var menuTitle: String {
        switch state {
        case .idle: return "Проверить обновления…"
        case .checking: return "Проверка обновлений…"
        case .downloading(let p): return "Скачивание обновления… \(Int(p * 100))%"
        case .installing: return "Установка обновления…"
        }
    }

    var isBusy: Bool { state != .idle }

    // MARK: - Interactive flow (кнопка в меню)

    func checkForUpdates() {
        guard state == .idle else { return }
        state = .checking
        Task { @MainActor in
            do {
                let release = try await Self.fetchLatestRelease()
                let remote = Self.stripV(release.tag_name)
                DebugLog.log("Updater: latest=\(remote), current=\(currentVersion)")
                guard Self.isNewer(remote, than: currentVersion) else {
                    state = .idle
                    alertInfo("У вас последняя версия",
                              "VoiceVoice \(currentVersion) — актуальная версия, обновление не требуется.")
                    return
                }
                guard let dmg = release.assets.first(where: { $0.name == Self.dmgAssetName }),
                      let dmgURL = URL(string: dmg.browser_download_url) else {
                    state = .idle
                    alertInfo("Обновление недоступно",
                              "В релизе \(release.tag_name) нет файла \(Self.dmgAssetName).")
                    return
                }
                guard confirm("Доступна версия \(remote)",
                              "У вас установлена \(currentVersion). Скачать и установить обновление? Приложение перезапустится.",
                              ok: "Обновить") else {
                    state = .idle
                    return
                }
                try await downloadAndInstall(dmgURL: dmgURL, expectedVersion: remote)
                state = .idle
                DebugLog.log("Updater: \(remote) installed, relaunching")
                Self.relaunch()   // не возвращается
            } catch {
                state = .idle
                DebugLog.log("Updater: FAILED — \(error.localizedDescription)")
                alertInfo("Не удалось обновиться", error.localizedDescription)
            }
        }
    }

    // MARK: - Steps

    /// Скачивает DMG (обновляя прогресс в `state`) и устанавливает его.
    /// Используется и интерактивным потоком, и отладочным `--update-test install`.
    func downloadAndInstall(dmgURL: URL, expectedVersion: String) async throws {
        state = .downloading(progress: 0)
        let localDMG = try await downloadWithProgress(dmgURL)
        defer { try? FileManager.default.removeItem(at: localDMG) }
        state = .installing
        try await Self.install(dmgAt: localDMG, expectedVersion: expectedVersion)
    }

    static func fetchLatestRelease() async throws -> Release {
        guard let url = URL(string: apiLatest) else { throw Err(m: "bad API URL") }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Err(m: "GitHub не ответил (нет сети или лимит API) — попробуйте позже")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    static func stripV(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Покомпонентное числовое сравнение версий: «1.1.10» новее «1.1.9».
    static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Скачивание с прогрессом — та же схема, что у загрузки моделей Sage.
    private func downloadWithProgress(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
                if let err { cont.resume(throwing: err); return }
                guard let tmp, let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    cont.resume(throwing: Err(m: "Не удалось скачать обновление (HTTP-ошибка)"))
                    return
                }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voicevoice-update-\(UUID().uuidString).dmg")
                do {
                    try FileManager.default.moveItem(at: tmp, to: dst)
                    cont.resume(returning: dst)
                } catch {
                    cont.resume(throwing: error)
                }
            }
            task.resume()
            Task { @MainActor [weak self] in
                while task.state == .running {
                    if let self, task.progress.fractionCompleted > 0 {
                        self.state = .downloading(progress: task.progress.fractionCompleted)
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
    }

    /// Монтирует DMG, сверяет версию бандла внутри с ожидаемой и подменяет
    /// /Applications/VoiceVoice.app (staging рядом + swap, чтобы не мержить
    /// поверх старого бандла остатки убранных файлов).
    private static func install(dmgAt dmg: URL, expectedVersion: String) async throws {
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicevoice-update-mount-\(UUID().uuidString)")
        try await runProcess("/usr/bin/hdiutil",
                             ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify",
                              "-mountpoint", mount.path])

        let fm = FileManager.default
        let staging = URL(fileURLWithPath: installPath + ".update-staging")
        do {
            let newApp = mount.appendingPathComponent("VoiceVoice.app")
            let plist = newApp.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = dict["CFBundleShortVersionString"] as? String else {
                throw Err(m: "В образе обновления не нашлось VoiceVoice.app")
            }
            guard version == expectedVersion else {
                throw Err(m: "Версия в образе (\(version)) не совпала с релизом (\(expectedVersion))")
            }
            try? fm.removeItem(at: staging)
            try await runProcess("/usr/bin/ditto", [newApp.path, staging.path])
        } catch {
            try? await runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        // Отмонтировать ДО подмены и синхронно: процесс может завершиться сразу
        // после установки (relaunch/exit), отложенный detach не успел бы выполниться
        // и образ оставался бы смонтированным. Данные уже скопированы в staging.
        try? await runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        let installed = URL(fileURLWithPath: installPath)
        if fm.fileExists(atPath: installed.path) {
            try fm.removeItem(at: installed)
        }
        try fm.moveItem(at: staging, to: installed)
    }

    /// Перезапуск: отвязанный шелл переоткрывает установленную копию после
    /// завершения текущего процесса (дочерний процесс переживает terminate).
    private static func relaunch() -> Never {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(installPath)\""]
        try? p.run()
        NSApp.terminate(nil)
        exit(0)   // terminate не возвращается, но компилятору нужен Never
    }

    /// Запуск процесса на фоновой очереди; при ненулевом коде — ошибка со stderr.
    private static func runProcess(_ path: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let errPipe = Pipe()
                p.standardError = errPipe
                p.standardOutput = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    guard p.terminationStatus == 0 else {
                        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                         encoding: .utf8) ?? ""
                        throw Err(m: "\((path as NSString).lastPathComponent) завершился с ошибкой: \(err.prefix(200))")
                    }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Alerts (LSUIElement-приложению нужна явная активация)

    private func alertInfo(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Отмена")
        return a.runModal() == .alertFirstButtonReturn
    }
}
