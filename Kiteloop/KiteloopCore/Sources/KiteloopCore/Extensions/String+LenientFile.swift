import Foundation

extension String {
    /// Reads a text file leniently: a byte that is not UTF-8 decodes as U+FFFD
    /// and the rest of the file still reads. Nil only when the file cannot be read.
    package init?(lenientContentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self = String(decoding: data, as: UTF8.self)
    }
}
