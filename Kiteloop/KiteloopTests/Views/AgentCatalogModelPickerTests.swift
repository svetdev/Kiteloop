import XCTest
import KiteloopCore
@testable import Kiteloop

/// The catalog's template editor opens on the template's own model, as every
/// other model picker does, and offers every model the app offers.
final class AgentCatalogModelPickerTests: XCTestCase {
    private func template(on model: String) -> AgentTemplate {
        var template = AgentTemplate(id: "t", name: "T")
        template.model = model
        return template
    }

    func testATemplateOutsideTheOldThreeOpensOnItsOwnModel() {
        for model in ["fable", "llama3.1", "copilot"] {
            XCTAssertEqual(CatalogModelSelection.initial(for: template(on: model)), model)
        }
    }

    func testABedrockProfileOpensOnItsFamily() {
        XCTAssertEqual(CatalogModelSelection.initial(for: template(on: "us.anthropic.claude-opus-4-8")), "opus")
    }

    func testANewTemplateOpensOnTheAppDefault() {
        XCTAssertEqual(CatalogModelSelection.initial(for: nil), ModelCatalog.defaultModelID)
    }

    func testThePickerOffersEveryModelTheAppOffers() {
        let offered = Set(ModelCatalog.pickerOptions(including: CatalogModelSelection.initial(for: nil)).map(\.id))
        XCTAssertTrue(Set(ModelCatalog.all.map(\.id)).isSubset(of: offered))
    }
}
