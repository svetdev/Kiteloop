import Foundation

/// What `POST /v1/agents/message` carries to the agent: the text, and the
/// images sent with it — a screenshot taken on the phone, most often. Either
/// may be empty, not both.
package struct AgentMessageContent {
    package let text: String
    package let attachments: [ChatAttachment]

    /// Why a body is not a message, with the status that says so.
    package struct Refusal: Error, Equatable {
        package let status: Int
        package let reason: String
    }

    /// Reads `message` and `attachments` from a request body. Each attachment
    /// is `{"filename", "mediaType", "data"}`, the data base64. Only the images
    /// a model's image block takes are accepted; anything else is a 415, and
    /// an image over `ChatAttachment.maxImageBytes` a 413.
    package static func parse(_ json: [String: Any]) -> Result<AgentMessageContent, Refusal> {
        let text = (json["message"] as? String) ?? ""
        let attachments: [ChatAttachment]
        switch images(json["attachments"]) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let parsed): attachments = parsed
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            return .failure(Refusal(status: 400, reason: "Body must include \"project\", \"agent\" and \"message\" (or \"attachments\")"))
        }
        return .success(AgentMessageContent(text: text, attachments: attachments))
    }

    private static func images(_ raw: Any?) -> Result<[ChatAttachment], Refusal> {
        guard let raw else { return .success([]) }
        guard let items = raw as? [[String: Any]] else {
            return .failure(Refusal(status: 400, reason: "\"attachments\" must be a list of {filename, mediaType, data}"))
        }
        var attachments: [ChatAttachment] = []
        for item in items {
            switch image(item) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let attachment): attachments.append(attachment)
            }
        }
        return .success(attachments)
    }

    private static func image(_ item: [String: Any]) -> Result<ChatAttachment, Refusal> {
        guard let filename = item["filename"] as? String, let mediaType = item["mediaType"] as? String,
              let encoded = item["data"] as? String, let data = Data(base64Encoded: encoded) else {
            return .failure(Refusal(status: 400, reason: "Each attachment needs \"filename\", \"mediaType\" and base64 \"data\""))
        }
        let attachment = ChatAttachment(filename: filename, data: data, mimeType: mediaType)
        guard attachment.isImage else {
            return .failure(Refusal(status: 415, reason: "\(filename) is \(mediaType); only PNG, JPEG, GIF and WebP images can be attached"))
        }
        guard data.count <= ChatAttachment.maxImageBytes else {
            return .failure(Refusal(status: 413, reason: "\(filename) is \(data.count) bytes; an image may be at most \(ChatAttachment.maxImageBytes)"))
        }
        return .success(attachment)
    }
}
