import SwiftUI

/// `?` icon next to a setting's label. On hover the icon scales up and tints,
/// and after a 200 ms dwell a custom popover with the hint text appears. The
/// native `.help(...)` modifier is also kept for accessibility (VoiceOver).
struct HelpHint: View {
    let text: String
    @State private var isHovering = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
            .scaleEffect(isHovering ? 1.2 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHovering)
            .accessibilityLabel(Text(text))
            .onHover { hovering in
                hoverTask?.cancel()
                isHovering = hovering
                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if Task.isCancelled { return }
                        showTooltip = true
                    }
                } else {
                    showTooltip = false
                }
            }
            .popover(isPresented: $showTooltip, arrowEdge: .top) {
                Text(text)
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var transcriber = Transcriber.shared
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var defaultInputName: String = ""

    var body: some View {
        Form {
            Section("Модель распознавания") {
                Picker(selection: $settings.modelName) {
                    ForEach(WhisperModelChoice.allCases) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Модель")
                        HelpHint(text: "Какую модель Whisper использовать для распознавания. Крупные модели точнее, но потребляют больше RAM и дольше работают. Квантованные (4-bit) — компромисс: занимают меньше памяти при незначительной потере качества.")
                    }
                }
                HStack {
                    Text("Статус:")
                    Text(modelStatus).foregroundStyle(.secondary)
                    Spacer()
                    Button("Загрузить сейчас") {
                        AppController.shared.warmUpIfNeeded()
                    }
                    .disabled(transcriber.state == .ready)
                    HelpHint(text: "Принудительно начать загрузку выбранной модели сейчас. Полезно, если выключена опция «Грузить при запуске» и хочется подготовить модель заранее, до первой диктовки.")
                    Button("Перезагрузить") {
                        transcriber.reloadIfModelChanged()
                    }
                    HelpHint(text: "Перезагрузить модель в память. Используйте, если сменили модель в списке выше или столкнулись с подозрительным поведением распознавания.")
                }
                Toggle(isOn: $settings.eagerLoad) {
                    HStack(spacing: 4) {
                        Text("Грузить модель при запуске приложения")
                        HelpHint(text: "Если включено, модель готова сразу — но запуск приложения занимает на 3–10 секунд дольше. Если выключено (по умолчанию), приложение стартует мгновенно, модель грузится при первом нажатии Fn или при открытии меню.")
                    }
                }
            }
            Section("Микрофон") {
                Picker(selection: $settings.inputDeviceUID) {
                    Text(defaultInputLabel).tag("")
                    ForEach(inputDevices) { d in
                        Text(d.name).tag(d.uid)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Устройство ввода")
                        HelpHint(text: "Какой микрофон использовать для записи. «Системный» автоматически следует за выбором macOS (System Settings → Sound → Input).")
                    }
                }
                HStack {
                    Button("Обновить список") { reloadInputDevices() }
                    HelpHint(text: "Пересканировать список доступных микрофонов. Полезно, если подключили новое устройство уже после открытия настроек.")
                    Spacer()
                }
            }

            Section("Активация") {
                Picker(selection: Binding(
                    get: { settings.hotkey },
                    set: { AppController.shared.reconfigureHotkey($0) }
                )) {
                    ForEach(HotkeyKind.allCases) { k in
                        Text(k.displayName).tag(k)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Hotkey (удержание)")
                        HelpHint(text: "Клавиша, удержание которой запускает запись и распознавание. Fn — стандарт macOS. Right Option / Right Cmd — альтернативы, если Fn уже занят другим приложением или системой.")
                    }
                }
                Toggle(isOn: $settings.autoPaste) {
                    HStack(spacing: 4) {
                        Text("Автоматически вставлять в активное поле (⌘V)")
                        HelpHint(text: "После распознавания VoiceVoice сам эмулирует ⌘V в активное приложение. Если выключено — текст просто кладётся в буфер обмена, вставлять нужно вручную.")
                    }
                }
                Toggle(isOn: $settings.alwaysKeepInClipboard) {
                    HStack(spacing: 4) {
                        Text("Оставлять текст в буфере обмена")
                        HelpHint(text: "Если включено — распознанный текст всегда остаётся в буфере обмена после диктовки, даже если он успешно вставился в активное поле. Если выключено — текст попадает в буфер только когда вставить его некуда (курсор не в поле ввода или вставка провалилась).")
                    }
                }
                Toggle(isOn: $settings.showResultHUD) {
                    HStack(spacing: 4) {
                        Text("Показывать HUD с результатом")
                        HelpHint(text: "Маленькое окошко в углу экрана с результатом распознавания. Если выключено — текст вставляется молча, без визуального подтверждения.")
                    }
                }
            }
            Section("Распознавание") {
                Picker(selection: $settings.language) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                    Text("Auto").tag("auto")
                } label: {
                    HStack(spacing: 4) {
                        Text("Язык")
                        HelpHint(text: "Язык, который ожидает услышать модель. Auto — определяет сама (может ошибаться на коротких фразах). Если вы всегда говорите на одном языке — лучше выбрать его явно, точность будет выше.")
                    }
                }
                Toggle(isOn: $settings.punctuationPrompt) {
                    HStack(spacing: 4) {
                        Text("Подсказывать модели про пунктуацию")
                        HelpHint(text: "Перед каждым распознаванием показываем модели короткий русский текст с запятыми, точками, тире и вопросительными знаками — модель видит это как «предыдущий контекст» и старается так же расставлять знаки в твоей речи. Полезно для квантованных моделей (4-bit), где пунктуация иногда теряется. На обычных моделях разница незаметна.")
                    }
                }

                Toggle(isOn: $settings.normalizeNumbers) {
                    HStack(spacing: 4) {
                        Text("Нормализовать числа")
                        HelpHint(text: "Убирает пробелы между разрядами чисел (\"1 425 689\" → \"1425689\") и удаляет лишнюю точку в конце, если последнее слово — это число (\"6532.\" → \"6532\"). Удобно для вставки в Google Sheets / Excel / Numbers. Десятичные дроби типа \"12.5\" не трогаются.")
                    }
                }

                Toggle(isOn: $settings.autoEmoji) {
                    HStack(spacing: 4) {
                        Text("Автоматически добавлять смайлы")
                        HelpHint(text: "Если включено, к распознанному тексту в конце добавляется один уместный смайл, когда во фразе встречается ключевое слово: «спасибо» → 🙏, «привет/здравствуй» → 👋, «поздравляю/с днём рождения/ура» → 🎉, «хаха/хах» → 😄, «лол/ржу» → 😂, «люблю/обожаю» → ❤️, «круто/супер/класс/отлично» → 👍, «извини/прости/sorry» → 🙏, «грустно/печально» → 😢, «огонь/пожар» → 🔥, «удачи» → 🍀, «пока/до свидания» → 👋. Не больше одного смайла на фразу; если такой смайл уже есть в тексте — повтор не добавляется.")
                    }
                }

                Toggle(isOn: $settings.fuzzyMatching) {
                    HStack(spacing: 4) {
                        Text("Нечёткое сравнение (fuzzy)")
                        HelpHint(text: "Если включено, словарь применяет правки даже когда фраза распозналась с ошибками. Например, запись «клод код → Claude Code» сработает и на «клот кот», «клоуд код», «клот код» и т.п. Сравнение по расстоянию Левенштейна на нормализованных строках (lowercase, ё→е).")
                    }
                }

                Toggle(isOn: $settings.autoLearnCorrections) {
                    HStack(spacing: 4) {
                        Text("Автодобавление исправлений в словарь")
                        HelpHint(text: "Если включено, после успешной вставки VoiceVoice ~5 минут наблюдает за активным полем и если вы исправляете распознанный текст вручную — соответствующие пары «как было → как стало» автоматически добавляются в словарь. Работает только в приложениях, где Accessibility отдаёт содержимое поля (нативные Cocoa-приложения: Notes, Safari, Pages и т.п.). В Claude Desktop, Slack, VS Code, Bitrix24, Max — не работает из-за ограничений их Accessibility-интеграции.")
                    }
                }

                if settings.fuzzyMatching {
                    HStack {
                        Text("Чувствительность fuzzy:")
                        HelpHint(text: "Максимально допустимая доля отличий (расстояние Левенштейна / длина) для матча. 10% — почти точное; 25% — рекомендуется; 50% — очень агрессивно, могут быть ложные срабатывания.")
                        Slider(value: $settings.fuzzyThreshold, in: 0.1...0.5)
                            .frame(maxWidth: 220)
                        Text(String(format: "%.0f%%", settings.fuzzyThreshold * 100))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Stepper(value: $settings.minConfirmedToApply, in: 1...10) {
                    HStack {
                        Text("Порог подтверждений для автоподстановки:")
                        HelpHint(text: "Сколько раз подряд распознаватель должен подтвердить одну и ту же интерпретацию фразы, прежде чем её вставить. 1 — мгновенно (быстро, но возможны мерцания во время диктовки). Больше — стабильнее, но с заметной задержкой.")
                        Text("\(settings.minConfirmedToApply)").bold()
                    }
                }
            }
            Section("О приложении") {
                LabeledContent {
                    HStack(spacing: 4) {
                        Text(appVersion).foregroundStyle(.secondary).monospacedDigit()
                        HelpHint(text: "Текущая версия VoiceVoice и номер сборки. Указывайте этот номер при сообщении об ошибке — он помогает понять, на какой именно версии воспроизводится проблема.")
                    }
                } label: {
                    Text("Версия")
                }
                Link(destination: URL(string: "https://vectrolab.ru")!) {
                    Label("Разработчик — VectroLab.ru", systemImage: "globe")
                }
                .help("Открыть сайт разработчика в браузере.")
                Link(destination: URL(string: "https://t.me/sergekruf")!) {
                    Label("Сообщить об ошибке (Telegram)", systemImage: "ladybug")
                }
                .help("Открыть Telegram-чат с разработчиком, чтобы сообщить о найденной ошибке.")
                Link(destination: URL(string: "https://t.me/sergekruf")!) {
                    Label("Предложить новую функцию (Telegram)", systemImage: "lightbulb")
                }
                .help("Открыть Telegram-чат с разработчиком, чтобы предложить идею или новую функцию.")
            }

            Section("Системные разрешения") {
                HStack {
                    Button("Открыть System Settings → Privacy & Security → Accessibility") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        NSWorkspace.shared.open(url)
                    }
                    HelpHint(text: "Нужно для эмуляции ⌘V в другие приложения. Без этого разрешения VoiceVoice не сможет автоматически вставлять распознанный текст — текст будет только попадать в буфер обмена.")
                    Spacer()
                }
                HStack {
                    Button("Открыть Microphone") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                        NSWorkspace.shared.open(url)
                    }
                    HelpHint(text: "Нужно для доступа к микрофону. Без этого разрешения VoiceVoice не сможет записывать звук — распознавание работать не будет.")
                    Spacer()
                }
                HStack {
                    Button("Открыть Keyboard → Dictation (отключи системную диктовку!)") {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation")!
                        NSWorkspace.shared.open(url)
                    }
                    HelpHint(text: "Системная диктовка macOS перехватывает Fn раньше нас. Её нужно выключить (System Settings → Keyboard → Dictation → off), иначе hotkey VoiceVoice не сработает.")
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear { reloadInputDevices() }
    }

    private var defaultInputLabel: String {
        defaultInputName.isEmpty ? "Системный (по умолчанию)" : "Системный — \(defaultInputName)"
    }

    private func reloadInputDevices() {
        inputDevices = AudioDevices.inputDevices()
        defaultInputName = AudioDevices.defaultInput()?.name ?? ""
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (build \(b))"
    }

    private var modelStatus: String {
        switch transcriber.state {
        case .notLoaded: return "не загружено"
        case .downloading(let p): return "загрузка \(Int(p * 100))%"
        case .loading: return "инициализация"
        case .ready: return "готово"
        case .error(let m): return "ошибка: \(m)"
        }
    }
}
