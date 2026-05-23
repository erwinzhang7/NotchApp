import Foundation

/// Module façade for the file shelf. Same shape as `ClipboardManager`: a `Services`
/// holder reachable via `FileShelf.shared.store`. Inspired in approach by NotchDrop
/// (MIT, Lakr233), but reimplemented here — no NotchDrop source is copied.
///
/// Privacy: held files are URL + bookmark references, never byte copies. Lives in RAM
/// only; nothing here is persisted to disk.
enum FileShelf {
    static let shared: Services = Services()

    final class Services {
        let store: FileShelfStore

        init() {
            self.store = FileShelfStore()
        }
    }
}
