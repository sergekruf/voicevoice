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
                // Ширина — точная, не maxWidth: с одним ограничением сверху поповер на
                // macOS 26 (SDK Xcode 27) считал высоту неверно и открывался пустой панелью
                // во весь экран. При фиксированной ширине высота однозначно следует из текста.
                Text(text)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .frame(width: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var parakeet = ParakeetTranscriber.shared
    @ObservedObject private var gigaam = GigaAMTranscriber.shared
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var defaultInputName: String = ""
    @State private var lastCheckEmpty = false

    /// State of whichever engine is currently selected.
    private var activeState: Transcriber.ModelState {
        switch settings.sttEngine {
        case .parakeet: return parakeet.state
        case .gigaAM: return gigaam.state
        }
    }

    private var availableEngines: [STTEngine] { STTEngine.allCases }

    var body: some View {
        Form {
            Section("Модель распознавания") {
                Picker(selection: $settings.sttEngineRaw) {
                    ForEach(availableEngines) { e in
                        Text(e.displayName).tag(e.rawValue)
                    }
                } label: {
                    Text("Движок")
                }
                Text("**GigaAM** — лучшее качество на русском, знаки препинания и числа из коробки (только русский). **Parakeet** — самый быстрый, 25 европейских языков; берите, если диктуете не только по-русски. Модель выбранного движка (~400–600 МБ) скачивается при первом выборе.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Статус:")
                    Text(modelStatus).foregroundStyle(.secondary)
                    Spacer()
                    Button("Загрузить сейчас") {
                        AppController.shared.warmUpIfNeeded()
                    }
                    .disabled(activeState == .ready)
                    HelpHint(text: "Принудительно начать загрузку выбранной модели сейчас (обычно она грузится сама при запуске приложения).")
                    Button("Перезагрузить") {
                        switch settings.sttEngine {
                        case .parakeet: parakeet.reload()
                        case .gigaAM: gigaam.reload()
                        }
                    }
                    HelpHint(text: "Перезагрузить модель в память. Используйте, если столкнулись с подозрительным поведением распознавания (смена движка выше перезагружает модель автоматически).")
                }
            }
            Section("Микрофон") {
                Toggle(isOn: $settings.instantRecordStart) {
                    HStack(spacing: 4) {
                        Text("Мгновенный старт записи")
                        HelpHint(text: "Аудио-движок работает постоянно: запись стартует сразу при нажатии клавиши (без ~0.5–1 с инициализации микрофона) и прихватывает полсекунды ДО нажатия — первые слова не теряются, даже если начать говорить одновременно с нажатием. Цена: macOS будет постоянно показывать индикатор использования микрофона. Звук до нажатия НЕ сохраняется — в памяти держится только скользящие полторы секунды, и на диск/в распознавание они попадают только при нажатой клавише.")
                    }
                }
                .onChange(of: settings.instantRecordStart) { _, _ in
                    AppController.shared.restartWarmListening()
                }
                Toggle(isOn: $settings.muteSystemAudioOnRecord) {
                    HStack(spacing: 4) {
                        Text("Приглушать звук во время записи")
                        HelpHint(text: "На время записи системный звук (музыка, видео, уведомления) выключается, чтобы не попадать в микрофон и не мешать распознаванию. Прежняя громкость возвращается сразу при отпускании клавиши. Если звук уже был выключен вручную — он таким и останется.")
                    }
                }
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
                .onChange(of: settings.inputDeviceUID) { _, _ in
                    // Тёплый движок привязан к устройству — перепривязываем сразу.
                    AppController.shared.restartWarmListening()
                }
                HStack {
                    Button("Обновить список") { reloadInputDevices() }
                    HelpHint(text: "Пересканировать список доступных микрофонов. Полезно, если подключили новое устройство уже после открытия настроек.")
                    Spacer()
                }
                Toggle(isOn: $settings.guardSystemInput) {
                    HStack(spacing: 4) {
                        Text("Не отдавать системный вход Bluetooth-наушникам")
                        HelpHint(text: "macOS при подключении Bluetooth-наушников сама делает их микрофон системным входом, и любое приложение, открывшее микрофон (звонок в браузере, диктовка), роняет звук наушников до телефонного качества — это гарнитурный профиль HFP. Если включено, VoiceVoice сразу возвращает системный вход на встроенный микрофон (или выбранный выше, если он не Bluetooth) — наушники остаются в качественном музыкальном режиме. Выключите, если хотите разговаривать в звонках через микрофон гарнитуры.")
                    }
                }
                .onChange(of: settings.guardSystemInput) { _, _ in
                    SystemInputGuard.shared.applySetting()
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
                        Text("Hotkey")
                        HelpHint(text: "Клавиша диктовки. Fn и Right Option работают удержанием (зажал — говоришь — отпустил) или свободной записью: двойное нажатие — запись идёт без удержания, можно работать за компьютером; ещё одно нажатие — стоп, текст вставляется туда, где сейчас курсор; двойной Esc — отмена. Caps Lock — переключателем: нажал — запись пошла, нажал ещё раз — стоп (macOS не сообщает отпускание Caps Lock, поэтому удержание для него невозможно; сам замок при этом не включается).")
                    }
                }
                if settings.hotkey == .fn, let action = Self.systemFnKeyAction {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("⚠️ Короткое нажатие 🌐/Fn у вас в macOS \(action). Для свободной записи (двойное нажатие Fn) это мешает — при каждом нажатии будет открываться системное окно. В настройках клавиатуры выберите «Нажатие клавиши 🌐» → «Ничего не делать».")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Открыть настройки клавиатуры") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Picker(selection: $settings.quickFixKeyRaw) {
                    ForEach(QuickFixKey.allCases) { k in Text(k.displayName).tag(k.rawValue) }
                } label: {
                    HStack(spacing: 4) {
                        Text("Быстрая правка")
                        HelpHint(text: "Выделите неправильно распознанное слово прямо в поле и один раз нажмите эту клавишу (без других клавиш) — появится окошко «Как правильно?». Enter заменит слово в тексте и добавит пару в словарь правок, чтобы в следующий раз оно распознавалось верно. Работает в любом приложении, в том числе там, где автообучение не видит поле (MAX, Termius, ChatGPT, браузеры). Если ничего не выделено, нажатие ничего не делает. Обычные русские слова в словарь не добавляются — такое правило портило бы другие фразы.")
                    }
                }
                .onChange(of: settings.quickFixKeyRaw) { _, _ in QuickFixService.shared.start() }
                Toggle(isOn: $settings.quietMode) {
                    HStack(spacing: 4) {
                        Text("Тихий режим — отключить все уведомления")
                        HelpHint(text: "Если включено, приложение перестаёт показывать любые тосты и всплывающие окна: HUD с результатом распознавания, тост о выученной правке словаря, индикатор загрузки модели и приветственный тост после онбординга. Индикатор записи (микрофон снизу экрана) всё равно остаётся видим — это функциональный элемент, без которого непонятно, идёт ли запись. Подходит для скринкастов, презентаций и сфокусированной работы.")
                    }
                }
            }
            Section("Распознавание") {
                Toggle(isOn: $settings.normalizeNumbers) {
                    HStack(spacing: 4) {
                        Text("Нормализовать числа")
                        HelpHint(text: "Числительные словами превращаются в цифры: «две тысячи пятьсот тридцать два» → 2532 (особенно важно для Parakeet — он пишет числа словами). Составные числа склеиваются только в правильном порядке разрядов, поэтому «один два три» останется отдельными числами, а «тысячи людей» не тронется. Дополнительно: пробелы между разрядами убираются (\"1 425 689\" → \"1425689\"), лишняя точка после числа в конце фразы удаляется (\"6532.\" → \"6532\") — удобно для вставки в таблицы. Десятичные дроби типа \"12.5\" не трогаются, одиночное «один/одна/одно» остаётся словом.")
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
                        HelpHint(text: "Сколько букв может отличаться, чтобы правило из словаря всё равно сработало: доля от длины фразы. 15% (рекомендуется) — одна буква в словах до 10 букв и две в более длинных: «клот» поймает и «клод», «Валберис» — «валберес». 25% — уже две буквы в словах от 6 букв, риск лишних замен в названиях. Обычные русские слова нечёткое сравнение не трогает при любом значении, слова короче 4 букв — тоже.")
                        Slider(value: $settings.fuzzyThreshold, in: 0.05...0.3)
                            .frame(maxWidth: 220)
                        Text(String(format: "%.0f%%", settings.fuzzyThreshold * 100))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker(selection: $settings.dictionaryCheckScheduleRaw) {
                    ForEach(DictionaryCheckSchedule.allCases) { s in
                        Text(s.displayName).tag(s.rawValue)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Проверять словарь автоматически")
                        HelpHint(text: "По расписанию приложение само выполняет «Ревизию…» словаря (какие правила стоит убрать: замены обычных слов, дубликаты, отклонённые) и показывает уведомление с числом находок. Ничего не удаляется без вашего подтверждения — открыть список можно кнопкой в уведомлении или в окне «Словарь правок». В тихом режиме уведомление не показывается.")
                    }
                }
                HStack {
                    Button("Проверить сейчас") {
                        if AppController.shared.runDictionaryCheck() == 0 { lastCheckEmpty = true }
                    }
                    if lastCheckEmpty {
                        Text("замечаний нет").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Stepper(value: $settings.minConfirmedToApply, in: 1...10) {
                    HStack {
                        Text("Порог подтверждений для автоподстановки:")
                        HelpHint(text: "Сколько подтверждений должна набрать пара «как было → как стало» в словаре правок, прежде чем словарь начнёт автоматически применять её к новым диктовкам. 1 (по умолчанию) — правка работает сразу после первого исправления. Выше — словарь осторожнее: пара должна подтвердиться несколько раз (повторными исправлениями того же слова или добавлением вручную). Запись также отключается сама, если откатов накопилось больше половины подтверждений.")
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
                    HelpHint(text: "Главное разрешение приложения: на нём держатся хоткей (глобальное отслеживание Fn/⌥/Caps Lock), эмуляция ⌘V для автовставки и чтение полей для автообучения словаря. Без него VoiceVoice не сможет ни запускаться по клавише, ни вставлять текст.")
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

    /// Что macOS делает по короткому нажатию 🌐/Fn (Клавиатура → «Нажатие клавиши 🌐»).
    /// nil — «Ничего не делать», двойному нажатию Fn не мешает.
    static var systemFnKeyAction: String? {
        switch UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType") ?? 0 {
        case 1: return "переключает раскладку"
        case 2: return "открывает панель эмодзи"
        case 3: return "запускает системную диктовку"
        default: return nil
        }
    }

    private var modelStatus: String {
        switch activeState {
        case .notLoaded: return "не загружено"
        case .downloading(let p): return "загрузка \(Int(p * 100))%"
        case .loading: return "инициализация"
        case .ready: return "готово"
        case .error(let m): return "ошибка: \(m)"
        }
    }

}
