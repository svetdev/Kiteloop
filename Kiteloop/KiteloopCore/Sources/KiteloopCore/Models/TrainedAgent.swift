import Foundation

package struct TrainedAgent: Identifiable, Hashable {
    package let id: String
    package let name: String
    package let model: String
    package let avatar: String
    package let description: String
    package let group: String?
    package let systemPrompt: String
    package let knowledgeFiles: [KnowledgeFile]
    package let basePath: URL

    package struct KnowledgeFile: Identifiable, Hashable {
        package let id: String
        package let name: String
        package let relativePath: String
        package let url: URL
        package let isDirectory: Bool
        package var children: [KnowledgeFile]

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, name: String, relativePath: String, url: URL, isDirectory: Bool, children: [KnowledgeFile]) {
            self.id = id
            self.name = name
            self.relativePath = relativePath
            self.url = url
            self.isDirectory = isDirectory
            self.children = children
        }
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(id: String, name: String, model: String, avatar: String, description: String, group: String?, systemPrompt: String, knowledgeFiles: [KnowledgeFile], basePath: URL) {
        self.id = id
        self.name = name
        self.model = model
        self.avatar = avatar
        self.description = description
        self.group = group
        self.systemPrompt = systemPrompt
        self.knowledgeFiles = knowledgeFiles
        self.basePath = basePath
    }
}
