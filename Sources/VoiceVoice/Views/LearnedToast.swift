import SwiftUI

struct LearnedToast: View {
    let corrections: [(wrong: String, right: String)]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(corrections.count == 1 ? "Добавлено в словарь" : "Добавлено в словарь — \(corrections.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<min(corrections.count, 3), id: \.self) { i in
                        HStack(alignment: .top, spacing: 6) {
                            Text(corrections[i].wrong)
                                .strikethrough()
                                .foregroundStyle(.white.opacity(0.65))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.top, 2)
                            Text(corrections[i].right)
                                .foregroundStyle(.white)
                                .fontWeight(.semibold)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if corrections.count > 3 {
                        Text("… и ещё \(corrections.count - 3)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            Spacer(minLength: 0)
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
