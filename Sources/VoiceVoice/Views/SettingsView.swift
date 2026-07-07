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
    @ObservedObject private var parakeet = ParakeetTranscriber.shared
    @ObservedObject private var gigaam = GigaAMTranscriber.shared
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var defaultInputName: String = ""

    /// State of whichever engine is currently selected.
    private var activeState: Transcriber.ModelState {
        switch settings.sttEngine {
        case .whisperKit: return transcriber.state
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
                    HStack(spacing: 4) {
                        Text("Движок")
                        HelpHint(text: "Какой движок распознавания использовать. Parakeet TDT v3 (по умолчанию) — быстрый движок NVIDIA через FluidAudio (CoreML/ANE): ~5× быстрее и меньше памяти, чем Whisper, хорошо распознаёт русский; модель ~600 МБ скачивается при первом выборе. WhisperKit (Whisper) — классический движок: шире поддержка языков. GigaAM v3 — русскоязычная модель Сбера с лучшим качеством на русском (в 2+ раза меньше ошибок, чем у Whisper) и встроенной пунктуацией/нормализацией; модель ~400 МБ скачивается при первом выборе, пост-обработка знаков отключается автоматически. Только русский язык.")
                    }
                }
                if settings.sttEngine == .whisperKit {
                    Picker(selection: $settings.modelName) {
                        ForEach(WhisperModelChoice.allCases) { m in
                            Text(m.displayName).tag(m.rawValue)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Модель Whisper")
                            HelpHint(text: "Какую модель Whisper использовать для распознавания. Крупные модели точнее, но потребляют больше RAM и дольше работают. Квантованные (4-bit) — компромисс: занимают меньше памяти при незначительной потере качества. Новая модель скачивается и перезагружается автоматически при выборе; первая компиляция для Neural Engine может занять несколько минут.")
                        }
                    }
                    .onChange(of: settings.modelName) { _, _ in
                        transcriber.reloadIfModelChanged()
                    }
                }
                HStack {
                    Text("Статус:")
                    Text(modelStatus).foregroundStyle(.secondary)
                    Spacer()
                    Button("Загрузить сейчас") {
                        AppController.shared.warmUpIfNeeded()
                    }
                    .disabled(activeState == .ready)
                    HelpHint(text: "Принудительно начать загрузку выбранной модели сейчас. Полезно, если выключена опция «Грузить при запуске» и хочется подготовить модель заранее, до первой диктовки.")
                    Button("Перезагрузить") {
                        switch settings.sttEngine {
                        case .parakeet: parakeet.reload()
                        case .gigaAM: gigaam.reload()
                        case .whisperKit: transcriber.reloadIfModelChanged()
                        }
                    }
                    HelpHint(text: "Перезагрузить модель в память. Используйте, если столкнулись с подозрительным поведением распознавания (смена модели в списке выше перезагружает её автоматически).")
                }
                Toggle(isOn: $settings.eagerLoad) {
                    HStack(spacing: 4) {
                        Text("Грузить модель при запуске приложения")
                        HelpHint(text: "Если включено, модель готова сразу — но запуск приложения занимает на 3–10 секунд дольше. Если выключено (по умолчанию), приложение стартует мгновенно, а модель грузится при первом нажатии hotkey (или по кнопке «Загрузить сейчас»).")
                    }
                }
                if settings.sttEngine == .whisperKit {
                    Toggle(isOn: $settings.eagerTranscription) {
                        HStack(spacing: 4) {
                            Text("Распознавать во время записи")
                            HelpHint(text: "Только для WhisperKit (Parakeet и так распознаёт мгновенно). Если включено (по умолчанию), законченные куски речи распознаются прямо во время диктовки — на отпускании клавиши остаётся распознать только короткий хвост. Результат идентичен обычному режиму (те же границы по тишине). Учти: при включённом «Показывать текст во время записи» распознавание во время записи работает в любом случае — этот тоггл влияет только при выключенном черновике.")
                        }
                    }
                    .disabled(settings.livePreview)
                }
                Toggle(isOn: $settings.livePreview) {
                    HStack(spacing: 4) {
                        Text("Показывать текст во время записи")
                        HelpHint(text: "Черновик распознанного текста появляется над индикатором записи по мере диктовки и обновляется каждые ~1–2 секунды. Всё распознаётся локально, как и сама диктовка. Черновик может отличаться от финального текста — финал проходит пунктуацию и словарь правок. Немного увеличивает нагрузку на Neural Engine во время записи.")
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
                        Text("Hotkey")
                        HelpHint(text: "Клавиша диктовки. Fn и Right Option работают удержанием (зажал — говоришь — отпустил). Caps Lock — переключателем: нажал — запись пошла, нажал ещё раз — стоп (macOS не сообщает отпускание Caps Lock, поэтому удержание для него невозможно; сам замок при этом не включается).")
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
                        HelpHint(text: "Маленькое окошко в углу экрана с результатом распознавания. Показывается только когда вставку не удалось подтвердить (текст остался в буфере, либо приложение не даёт проверить поле) — при обычной успешной вставке текст просто появляется в поле без окошка. Если выключено — окошко не показывается никогда. При включённом «тихом режиме» опция игнорируется.")
                    }
                }
                .disabled(settings.quietMode)
                Toggle(isOn: $settings.quietMode) {
                    HStack(spacing: 4) {
                        Text("Тихий режим — отключить все уведомления")
                        HelpHint(text: "Если включено, приложение перестаёт показывать любые тосты и всплывающие окна: HUD с результатом распознавания, тост о выученной правке словаря, индикатор загрузки модели и приветственный тост после онбординга. Индикатор записи (микрофон снизу экрана) всё равно остаётся видим — это функциональный элемент, без которого непонятно, идёт ли запись. Подходит для скринкастов, презентаций и сфокусированной работы. Перекрывает «Показывать HUD с результатом».")
                    }
                }
            }
            Section("Распознавание") {
                if settings.sttEngine == .whisperKit {
                    Picker(selection: $settings.language) {
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                        Text("Auto").tag("auto")
                    } label: {
                        HStack(spacing: 4) {
                            Text("Язык")
                            HelpHint(text: "Язык, который ожидает услышать модель Whisper. Auto — определяет сама (может ошибаться на коротких фразах). Если вы всегда говорите на одном языке — лучше выбрать его явно, точность будет выше. Parakeet определяет язык всегда автоматически, поэтому для него эта настройка скрыта.")
                        }
                    }
                    Toggle(isOn: $settings.punctuationPrompt) {
                        HStack(spacing: 4) {
                            Text("Подсказывать модели про пунктуацию")
                            HelpHint(text: "Только для WhisperKit. Перед каждым распознаванием показываем модели короткий русский текст с запятыми, точками, тире и вопросительными знаками — модель видит это как «предыдущий контекст» и старается так же расставлять знаки в твоей речи. Полезно для квантованных моделей (4-bit), где пунктуация иногда теряется. На обычных моделях разница незаметна.")
                        }
                    }
                }

                Toggle(isOn: $settings.normalizeNumbers) {
                    HStack(spacing: 4) {
                        Text("Нормализовать числа")
                        HelpHint(text: "Числительные словами превращаются в цифры: «две тысячи пятьсот тридцать два» → 2532 (особенно важно для Parakeet — он пишет числа словами). Составные числа склеиваются только в правильном порядке разрядов, поэтому «один два три» останется отдельными числами, а «тысячи людей» не тронется. Дополнительно: пробелы между разрядами убираются (\"1 425 689\" → \"1425689\"), лишняя точка после числа в конце фразы удаляется (\"6532.\" → \"6532\") — удобно для вставки в таблицы. Десятичные дроби типа \"12.5\" не трогаются, одиночное «один/одна/одно» остаётся словом.")
                    }
                }

                Toggle(isOn: $settings.punctuationModel) {
                    HStack(spacing: 4) {
                        Text("Нейро-пунктуация (модель)")
                        HelpHint(text: "Экспериментально. Расставляет знаки препинания и заглавные буквы нейросетевой моделью (RUPunct, ~56 МБ, целиком на устройстве) вместо набора правил. Особенно полезно для движка Parakeet, который на длинных записях не ставит знаки. Модель загружается в память при первом использовании. Когда включено — заменяет «Исправлять знаки в конце предложений». Работает только для русского.")
                    }
                }
                Toggle(isOn: $settings.fixPunctuation) {
                    HStack(spacing: 4) {
                        Text("Исправлять знаки в конце предложений")
                        HelpHint(text: "Движки иногда ошибаются со знаком в конце предложения (вопрос → точка, утверждение → вопрос). Простые русские правила исправляют очевидные случаи:\n\n• Частица «ли» в предложении («Был ли ты вчера») → терминатор становится «?». Устойчивые обороты «вряд ли / едва ли / чуть ли / мало ли / то ли» вопросом не считаются.\n• Предложение начинается с вопросительного слова (что / где / когда / почему / куда / откуда / зачем / кто / сколько / разве / неужели), допустимо после дискурсивных «А / Ну / Так / И» — «.» меняется на «?». Исключения: «что-то / где-нибудь…», «что касается / что ж / что бы», «разве что» — это не вопросы.\n• Длинное предложение (≥ 5 слов) без вопросительных маркеров, оканчивающееся на «?» → меняется на «.» (вероятно, неверно понятая интонация).\n\nЗнак «!» не трогается — восклицание и эмоциональный вопрос неразличимы без аудио. «Как» и «какой» не считаются вопросительными («Как красиво!»). Неактивно при включённой нейро-пунктуации — она заменяет эти правила.")
                    }
                }
                .disabled(settings.punctuationModel)

                Toggle(isOn: $settings.autoFormat) {
                    HStack(spacing: 4) {
                        Text("Авто-форматирование (списки, абзацы)")
                        HelpHint(text: "Если включено, распознанная речь автоматически форматируется:\n• Перечисления «первое… второе…» (2+ подряд) и «сначала… потом… затем…» (3+ разных) превращаются в нумерованный список.\n• Конструкции «список покупок: хлеб, молоко, масло, сыр» (3+ элемента через запятую после двоеточия) — в маркированный список.\n• Фразы «новый абзац», «с новой строки» вставляют перевод строки.\n\nВыключено по умолчанию: переводы строк ломают узкие однострочные поля ввода. Включай, если чаще диктуешь в редакторы и заметки.")
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
                        HelpHint(text: "Сколько подтверждений должна набрать пара «как было → как стало» в словаре правок, прежде чем словарь начнёт автоматически применять её к новым диктовкам. 1 (по умолчанию) — правка работает сразу после первого исправления. Выше — словарь осторожнее: пара должна подтвердиться несколько раз (повторными исправлениями того же слова или добавлением вручную). Запись также отключается сама, если откатов накопилось больше половины подтверждений.")
                        Text("\(settings.minConfirmedToApply)").bold()
                    }
                }
            }
            Section("Фильтр галлюцинаций") {
                HStack(spacing: 4) {
                    Text("Фразы для удаления (по одной на строку)")
                        .font(.subheadline)
                    HelpHint(text: "Whisper на тишине/шуме иногда выдаёт заученные с YouTube «титры» («Спасибо за просмотр», «Подписывайтесь на канал» и т.п.). Эти фразы удаляются из результата, но только если совпадают с ЦЕЛЫМ предложением — настоящая речь («Спасибо за внимание, коллеги») не страдает. Добавляй сюда артефакты, которые встречаешь у себя. Технические мусорные вставки (DimaTorzok, amara.org, «Редактор субтитров…») отсекаются автоматически и в этот список добавлять не нужно.")
                    Spacer()
                    Button("Сбросить") {
                        settings.hallucinationBlocklist = Transcriber.defaultHallucinationBlocklistText
                    }
                    .controlSize(.small)
                }
                TextEditor(text: $settings.hallucinationBlocklist)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
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
