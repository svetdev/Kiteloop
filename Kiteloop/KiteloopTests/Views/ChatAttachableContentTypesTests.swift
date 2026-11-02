import UniformTypeIdentifiers
import XCTest
@testable import Kiteloop

/// The paperclip's open panel offers the files a drop would attach: text is
/// sent as text and pictures as images, so neither may be greyed out — while a
/// binary document the model cannot read stays unpickable.
final class ChatAttachableContentTypesTests: XCTestCase {

    func testTextAndPictureFilesAreAttachable() {
        for ext in ["csv", "yaml", "html", "xml", "md", "json", "swift", "heic", "tiff", "svg"] {
            XCTAssertTrue(isAttachable(ext), "\(ext) should be pickable from the paperclip")
        }
    }

    func testBinaryDocumentsAreNotAttachable() {
        for ext in ["pdf", "zip"] {
            XCTAssertFalse(isAttachable(ext), "\(ext) should stay greyed out")
        }
    }

    private func isAttachable(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else {
            XCTFail("no UTType for .\(ext)")
            return false
        }
        return ChatView.attachableContentTypes.contains { type.conforms(to: $0) }
    }
}
