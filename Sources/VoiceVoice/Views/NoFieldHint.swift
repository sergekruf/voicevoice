import SwiftUI

struct NoFieldHint: View {
    /// true — ⌘V отправлен, но курсор мог уйти из поля; false — поля не было вовсе.
    var kept = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.cursor.ibeam")
                .font(.system(size: 22))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text(kept ? "Текст ещё и в буфере обмена" : "Поле ввода не найдено")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(kept ? "Проверить вставку не удалось. Если текста нет в поле — поставь курсор и нажми ⌘V."
                          : "Поставь курсор в нужное поле и нажми ⌘V — текст уже в буфере")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
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
