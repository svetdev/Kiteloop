import AppKit
import XCTest
@testable import Kiteloop

/// Enter in the chat input first offers an open slash or mention popover its
/// highlighted row, and sends the message only when no popover takes it.
@MainActor
final class InputTextViewEnterKeyTests: XCTestCase {

    private let returnKeyCode: UInt16 = 36

    private var submits = 0
    private var actions: [InputKeyAction] = []

    private func makeInput(popoverOpen: Bool) -> InputTextView {
        let view = InputTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        view.onSubmit = { [unowned self] in submits += 1 }
        view.onKeyAction = { [unowned self] action in
            actions.append(action)
            return action == .popoverConfirm && popoverOpen
        }
        return view
    }

    private func returnKey(shift: Bool) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shift ? [.shift] : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: returnKeyCode
        ))
    }

    func testEnterWithAPopoverOpenConfirmsItAndDoesNotSubmit() throws {
        let input = makeInput(popoverOpen: true)

        input.keyDown(with: try returnKey(shift: false))

        XCTAssertEqual(submits, 0)
        XCTAssertEqual(actions.filter { $0 == .popoverConfirm }.count, 1)
    }

    func testEnterWithNoPopoverOpenSubmitsOnce() throws {
        let input = makeInput(popoverOpen: false)

        input.keyDown(with: try returnKey(shift: false))

        XCTAssertEqual(submits, 1)
    }

    func testShiftEnterNeitherSubmitsNorConfirms() throws {
        let input = makeInput(popoverOpen: true)

        input.keyDown(with: try returnKey(shift: true))

        XCTAssertEqual(submits, 0)
        XCTAssertFalse(actions.contains(.popoverConfirm))
    }
}
