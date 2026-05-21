import AppKit

/// Snapshot of `NSPasteboard.general` contents — preserves all items and all data types
/// per item, so we can restore exactly what the user had on the clipboard before we
/// briefly hijacked it for a paste.
///
/// Important: after `NSPasteboard.clearContents()` the original NSPasteboardItems become
/// invalidated. We therefore deep-copy all Data values into our own storage at capture
/// time, and build fresh `NSPasteboardItem` instances on restore.
struct ClipboardSnapshot {
    let primaryString: String?
    let items: [[NSPasteboard.PasteboardType: Data]]
    let wasEmpty: Bool

    static let empty = ClipboardSnapshot(primaryString: nil, items: [], wasEmpty: true)

    /// Capture the current clipboard. The caller is responsible for detecting "this is our
    /// leftover" and using `.empty` instead — see `TextInserter.isOursLeftover`.
    static func capture() -> ClipboardSnapshot {
        let pb = NSPasteboard.general
        let primary = pb.string(forType: .string)

        guard let pbItems = pb.pasteboardItems, !pbItems.isEmpty else {
            DebugLog.log("Clipboard: capture — empty (primaryString=\(primary?.prefix(40) ?? "nil"))")
            return ClipboardSnapshot(primaryString: primary, items: [], wasEmpty: primary == nil)
        }
        let captured: [[NSPasteboard.PasteboardType: Data]] = pbItems.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = Data(data)
                }
            }
            return dict
        }
        DebugLog.log("Clipboard: capture — \(captured.count) item(s), primaryString=\(primary?.prefix(40) ?? "nil")")
        return ClipboardSnapshot(primaryString: primary, items: captured, wasEmpty: false)
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if wasEmpty {
            DebugLog.log("Clipboard: restore — was empty, leaving cleared")
            return
        }
        if !items.isEmpty {
            let pbItems = items.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict {
                    item.setData(data, forType: type)
                }
                return item
            }
            let ok = pb.writeObjects(pbItems)
            DebugLog.log("Clipboard: restore — writeObjects(\(pbItems.count) items) ok=\(ok), now=\(pb.string(forType: .string)?.prefix(40) ?? "nil")")
            return
        }
        // Fallback: at least restore the primary string if we lost the items.
        if let s = primaryString {
            pb.setString(s, forType: .string)
            DebugLog.log("Clipboard: restore — string fallback ok, now=\(s.prefix(40))")
        } else {
            DebugLog.log("Clipboard: restore — no string and no items; cleared")
        }
    }
}
