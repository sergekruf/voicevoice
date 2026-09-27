import SwiftUI

/// Итог автопроверки словаря: сколько правил стоит убрать. Сам ничего не меняет —
/// только зовёт открыть словарь.
struct DictionaryCheckToast: View {
    let auditCount: Int
    var onOpen: (() -> Void)? = nil

    private var lines: [String] {
        var out: [String] = []
        if auditCount > 0 { out.append("\(auditCount) правил стоит проверить и убрать") }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 22))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text("Проверка словаря правок")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer()
            if let onOpen {
                Button("Открыть", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .padding(4)
    }
}
