import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Batch offline file transcription. Decodes each picked audio file (any format —
/// see AudioFileDecoder) and runs it through the active engine + text pipeline,
/// updating per-file status so the window can show progress and results.
@MainActor
final class FileTranscribeController: ObservableObject {
    static let shared = FileTranscribeController()
    private init() {}

    enum JobStatus: Equatable {
        case pending, decoding, transcribing, done, failed
        var label: String {
            switch self {
            case .pending: return "в очереди"
            case .decoding: return "декодирование…"
            case .transcribing: return "распознавание…"
            case .done: return "готово"
            case .failed: return "ошибка"
            }
        }
    }

    struct Job: Identifiable {
        let id = UUID()
        let url: URL
        var status: JobStatus = .pending
        var text: String = ""
        var error: String?
        var name: String { url.lastPathComponent }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var running = false
    @Published var selectedID: Job.ID?

    var completedCount: Int { jobs.filter { $0.status == .done || $0.status == .failed }.count }
    var progress: Double { jobs.isEmpty ? 0 : Double(completedCount) / Double(jobs.count) }

    /// Show an open panel and enqueue the chosen files.
    func promptAndStart() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.audioContentTypes()
        panel.allowsOtherFileTypes = true   // ogg/opus may not map to a known UTType
        panel.prompt = "Транскрибировать"
        panel.message = "Выберите аудиофайлы (можно несколько)"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { start(urls: panel.urls) }
    }

    func start(urls: [URL]) {
        let fresh = urls.map { Job(url: $0) }
        jobs.append(contentsOf: fresh)
        if selectedID == nil { selectedID = fresh.first?.id }
        if !running { Task { await run() } }
    }

    func clearFinished() {
        jobs.removeAll { $0.status == .done || $0.status == .failed }
        if let sel = selectedID, !jobs.contains(where: { $0.id == sel }) {
            selectedID = jobs.first?.id
        }
    }

    private func run() async {
        running = true
        defer { running = false }
        while let job = jobs.first(where: { $0.status == .pending }) {
            let id = job.id
            let url = job.url
            setStatus(id, .decoding)
            do {
                let samples = try await Task.detached(priority: .userInitiated) {
                    try AudioFileDecoder.decode(url: url)
                }.value
                guard samples.count >= Int(AudioRecorder.targetSampleRate * 0.25) else {
                    fail(id, "Слишком короткое или пустое аудио")
                    continue
                }
                setStatus(id, .transcribing)
                let text = await AppController.shared.transcribeAudioSamples(samples)
                if let i = index(of: id) {
                    jobs[i].text = text
                    if text.isEmpty {
                        jobs[i].status = .failed
                        jobs[i].error = "Пустой результат распознавания"
                    } else {
                        jobs[i].status = .done
                    }
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                fail(id, msg)
            }
        }
    }

    private func index(of id: Job.ID) -> Int? { jobs.firstIndex(where: { $0.id == id }) }
    private func setStatus(_ id: Job.ID, _ s: JobStatus) { if let i = index(of: id) { jobs[i].status = s } }
    private func fail(_ id: Job.ID, _ message: String) {
        if let i = index(of: id) { jobs[i].status = .failed; jobs[i].error = message }
    }

    static func audioContentTypes() -> [UTType] {
        var types: [UTType] = [.audio]
        for ext in AudioFileDecoder.supportedExtensions {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return Array(Set(types))
    }
}

struct FileTranscribeView: View {
    @ObservedObject private var controller = FileTranscribeController.shared

    private var selectedJob: FileTranscribeController.Job? {
        controller.jobs.first { $0.id == controller.selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.jobs.isEmpty {
                emptyState
            } else {
                HSplitView {
                    fileList.frame(minWidth: 240, idealWidth: 300)
                    detail.frame(minWidth: 320)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                controller.promptAndStart()
            } label: { Label("Добавить файлы…", systemImage: "plus") }

            if controller.running {
                ProgressView().controlSize(.small)
            }
            if !controller.jobs.isEmpty {
                ProgressView(value: controller.progress)
                    .frame(maxWidth: 200)
                Text("\(controller.completedCount)/\(controller.jobs.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if controller.jobs.contains(where: { $0.status == .done || $0.status == .failed }) {
                Button("Очистить готовые") { controller.clearFinished() }
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Перетащите или добавьте аудиофайлы для распознавания")
                .foregroundStyle(.secondary)
            Text("ogg, mp3, m4a, wav, flac, opus и др. Можно несколько сразу.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Button { controller.promptAndStart() } label: { Label("Добавить файлы…", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        List(controller.jobs, selection: $controller.selectedID) { job in
            HStack(spacing: 8) {
                statusIcon(job.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name).lineLimit(1).font(.system(size: 12))
                    Text(job.error ?? job.status.label)
                        .font(.system(size: 10))
                        .foregroundStyle(job.status == .failed ? .red : .secondary)
                        .lineLimit(1)
                }
            }
            .tag(job.id)
        }
    }

    @ViewBuilder
    private func statusIcon(_ s: FileTranscribeController.JobStatus) -> some View {
        switch s {
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .decoding, .transcribing: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let job = selectedJob {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.name).font(.headline).lineLimit(1)
                    Spacer()
                    if job.status == .done {
                        Button { copy(job.text) } label: { Image(systemName: "doc.on.doc") }
                            .help("Скопировать текст")
                        Button { save(job) } label: { Image(systemName: "square.and.arrow.down") }
                            .help("Сохранить .txt рядом с аудио")
                    }
                }
                if let err = job.error {
                    Text(err).foregroundStyle(.red).font(.system(size: 12))
                }
                ScrollView {
                    Text(job.text.isEmpty ? "—" : job.text)
                        .textSelection(.enabled)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
            .padding(12)
        } else {
            Text("Выберите файл слева").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save(_ job: FileTranscribeController.Job) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = job.url.deletingPathExtension().lastPathComponent + ".txt"
        panel.directoryURL = job.url.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            try? job.text.data(using: .utf8)?.write(to: url)
        }
    }
}
