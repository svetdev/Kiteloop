import Foundation

/// Folds chat attachments into a plain-text user turn.
///
/// `ClaudeCodeCLIRuntime` hands attachments to the CLI as typed content blocks.
/// The Ollama and Copilot backends send a `messages` array whose contents are
/// plain strings, with nowhere to put a block — so an attachment has to become
/// part of the turn's text, under the same `--- <filename> ---` heading the
/// Claude path uses for a non-image file.
///
/// An attachment that cannot be represented as text — an image, or bytes that
/// `ChatAttachment.textContent` takes as binary — is named under that same heading with a line saying it
/// was not sent. The user's file is then either in the prompt or accounted for
/// in it, rather than vanishing between the transcript and the request.
package enum PlainTextAttachments {
    /// The user turn to send: `text` unchanged when there is nothing attached.
    package static func fold(text: String, attachments: [ChatAttachment]) -> String {
        guard !attachments.isEmpty else { return text }

        var sections: [String] = []
        if !text.isEmpty {
            sections.append(text)
        }
        for attachment in attachments {
            sections.append("--- \(attachment.filename) ---\n\(body(of: attachment))")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func body(of attachment: ChatAttachment) -> String {
        if attachment.isImage {
            return "[not sent: this model cannot see images]"
        }
        guard let text = attachment.textContent else {
            return "[not sent: this file is not text this model can read]"
        }
        return text
    }
}
