import SwiftUI

struct ResultHUD: View {
    let record: TranscriptionRecord
    @ObservedObject private var controller = AppController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top block — status header + Edit button.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    if let subtitle = statusSubtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button {
                    EditAndLearnController.shared.open(record: record)
                    HUDManager.shared.hideResult()
                } label: {
                    Label("Edit & Learn", systemImage: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Thin separator: makes it obvious where the hint ends and the recognized text begins.
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            // Bottom block — the recognized text itself, on a slightly darker background.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 2)
                Text(record.appliedText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04))
        }
        .frame(maxWidth: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.84))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(4)
    }

    private var statusIcon: String {
        switch controller.lastPasteOutcome {
        case .pasted: return "checkmark.circle.fill"
        case .pastedNoAutoLearn: return "checkmark.circle.fill"
        case .clipboardOnly: return "text.cursor.ibeam"
        case .failed: return "exclamationmark.triangle.fill"
        case .skipped: return "doc.on.clipboard"
        case .pending: return "ellipsis.circle"
        }
    }

    private var statusColor: Color {
        switch controller.lastPasteOutcome {
        case .pasted: return .green
        case .pastedNoAutoLearn: return .green
        case .clipboardOnly: return .cyan
        case .failed: return .yellow
        case .skipped: return .gray
        case .pending: return .white.opacity(0.6)
        }
    }

    private var statusTitle: String {
        switch controller.lastPasteOutcome {
        case .pasted: return "Вставлено"
        case .pastedNoAutoLearn: return "Вставлено"
        case .clipboardOnly: return "Поле ввода не найдено"
        case .failed: return "Авто-вставка не сработала"
        case .skipped: return "Скопировано в буфер"
        case .pending: return "Вставка…"
        }
    }

    private var statusSubtitle: String? {
        switch controller.lastPasteOutcome {
        case .pasted: return nil
        case .pastedNoAutoLearn: return "В этом приложении автообучение недоступно. Жми Edit & Learn, чтобы добавить исправление в словарь вручную."
        case .clipboardOnly: return "Поставь курсор в нужное поле и нажми ⌘V — текст в буфере"
        case .failed: return "Нажми ⌘V в активном поле — текст в буфере"
        case .skipped: return "Авто-вставка отключена в настройках"
        case .pending: return nil
        }
    }
}
