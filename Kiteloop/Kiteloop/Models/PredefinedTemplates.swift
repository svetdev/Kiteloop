import Foundation
import KiteloopCore

struct QuickAddPreset: Identifiable, Sendable {
    let id: String
    let label: String
    let icon: String
    let model: String
    let runtimeKind: String
    let systemPrompt: String
    let avatar: String

    static let all: [QuickAddPreset] = [
        QuickAddPreset(
            id: "quick-llama3.1",
            label: "Llama 3.1 (Local)",
            icon: "desktopcomputer",
            model: "llama3.1",
            runtimeKind: "ollama",
            systemPrompt: "You are a helpful coding assistant running locally via Ollama. Write clean, concise code. Be direct.",
            avatar: "🦙"
        ),
        QuickAddPreset(
            id: "quick-qwen-coder",
            label: "Qwen Coder (Local)",
            icon: "desktopcomputer",
            model: "qwen2.5-coder",
            runtimeKind: "ollama",
            systemPrompt: "You are Qwen Coder, a local coding assistant specializing in code generation and refactoring. Be precise and concise.",
            avatar: "🤖"
        ),
        QuickAddPreset(
            id: "quick-copilot",
            label: "GitHub Copilot",
            icon: "arrow.triangle.branch",
            model: "copilot",
            runtimeKind: "copilot",
            systemPrompt: "You are a code review assistant powered by GitHub Copilot. Provide concise, actionable feedback on code quality, bugs, and improvements.",
            avatar: "🐙"
        ),
    ]
}

extension AgentTemplate {
    static let claude = AgentTemplate(
        id: "template-claude",
        name: "Claude",
        model: ModelCatalog.defaultModelID,
        systemPrompt: """
        You are Claude, a full-capability AI assistant. You can do everything: read, write, and edit files, \
        run shell commands, search codebases, create commits, manage git, install dependencies, run tests, \
        debug issues, refactor code, write documentation, and anything else that's possible via a terminal. \
        You are the default generalist — handle any task the user throws at you directly.

        You can also summon task specialists using the hire_agent tool when the work would benefit from \
        a dedicated agent (e.g., a QA specialist for comprehensive testing, or a Research agent for \
        deep investigation). Available roles can be found in the agent catalog. \
        You can fire agents that are no longer needed using fire_agent.
        """,
        tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "publish_event", "propose_memory", "ask_human", "hire_agent", "fire_agent", "recall_knowledge", "save_knowledge", "web_navigate", "web_screenshot", "web_read_text", "web_console", "web_inspect_head", "web_list_elements", "web_click", "web_type", "web_scroll"],
        denied: [],
        permissionMode: "acceptEdits",
        subscriptions: [],
        description: "Full-capability generalist — does everything, can summon specialists",
        avatar: "🏰"
    )

    static let catalog: [String: AgentTemplate] = [
        "coder": AgentTemplate(
            id: "catalog-coder",
            name: "Coder",
            model: ModelCatalog.defaultModelID,
            systemPrompt: """
            You are a senior developer. Write clean, testable code.
            When your work results in a PR, call publish_event with event "pr_ready" and payload containing the branch name and PR URL.
            Use propose_memory to save important decisions or patterns you discover.
            """,
            tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "publish_event", "propose_memory", "recall_knowledge", "save_knowledge"],
            denied: [],
            permissionMode: "acceptEdits",
            subscriptions: [],
            description: "Senior developer — writes and debugs code",
            avatar: "🤖",
            group: "Engineering"
        ),
        "reviewer": AgentTemplate(
            id: "catalog-reviewer",
            name: "Reviewer",
            model: ModelCatalog.defaultModelID,
            systemPrompt: """
            You are a code reviewer. Focus on correctness, security, performance, and maintainability.
            You receive pr_ready events automatically. Review the code changes thoroughly.
            When done, call publish_event with event "review_complete" and your summary.
            Use ask_human when you need clarification from the developer.
            """,
            tools: ["Read", "Bash", "Glob", "Grep", "message_agent", "publish_event", "ask_human", "propose_memory", "recall_knowledge", "save_knowledge"],
            denied: ["Edit", "Write"],
            permissionMode: "plan",
            subscriptions: ["pr_ready"],
            description: "Code reviewer — checks quality and security",
            avatar: "🦉",
            group: "Quality"
        ),
        "researcher": AgentTemplate(
            id: "catalog-researcher",
            name: "Researcher",
            model: ModelCatalog.defaultModelID,
            systemPrompt: """
            You are a technical researcher. Investigate APIs, dependencies, architectures, and provide detailed findings.
            Use propose_memory to save research findings for the team.
            Use ask_human when you need direction on what to investigate.
            """,
            tools: ["Read", "Bash", "Glob", "Grep", "message_agent", "publish_event", "propose_memory", "ask_human", "recall_knowledge", "save_knowledge"],
            denied: ["Edit", "Write"],
            permissionMode: "plan",
            subscriptions: [],
            description: "Researcher — explores code and finds patterns",
            avatar: "🔮",
            group: "Research"
        ),
        "frontend": AgentTemplate(
            id: "catalog-frontend",
            name: "Frontend",
            model: ModelCatalog.defaultModelID,
            systemPrompt: """
            You are a frontend specialist. React, TypeScript, CSS, accessibility, responsive design.
            Write clean component code. Test in the browser. Use propose_memory for design decisions.
            """,
            tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "publish_event", "propose_memory", "recall_knowledge", "save_knowledge", "web_navigate", "web_screenshot", "web_read_text", "web_console", "web_inspect_head", "web_list_elements", "web_click", "web_type", "web_scroll"],
            denied: [],
            permissionMode: "acceptEdits",
            subscriptions: [],
            description: "Frontend specialist — UI, React, CSS",
            avatar: "🎨",
            group: "Engineering"
        ),
        "infra": AgentTemplate(
            id: "catalog-infra",
            name: "Infra",
            model: ModelCatalog.defaultModelID,
            systemPrompt: """
            You are a DevOps/infrastructure specialist. Docker, Kubernetes, CI/CD, cloud services, monitoring, deployments.
            Be careful with destructive operations. Use propose_memory for infrastructure decisions.
            """,
            tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "publish_event", "propose_memory", "recall_knowledge", "save_knowledge"],
            denied: [],
            permissionMode: "acceptEdits",
            subscriptions: [],
            description: "DevOps — Docker, K8s, CI/CD, cloud",
            avatar: "⚔️",
            group: "Engineering"
        ),
        "qa": AgentTemplate(
            id: "catalog-qa",
            name: "QA",
            model: ModelCatalog.defaultModelID,
            systemPrompt: """
            You are a QA specialist. Write comprehensive tests, find edge cases, verify behavior.
            Focus on test coverage and regression prevention. Run tests after writing them.
            """,
            tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "publish_event", "propose_memory", "recall_knowledge", "save_knowledge", "web_navigate", "web_screenshot", "web_read_text", "web_console", "web_inspect_head", "web_list_elements", "web_click", "web_type", "web_scroll"],
            denied: [],
            permissionMode: "acceptEdits",
            subscriptions: ["task_complete"],
            description: "QA — writes tests, finds edge cases",
            avatar: "🐍",
            group: "Quality"
        ),
        "designer": AgentTemplate(
            id: "catalog-designer",
            name: "Designer",
            model: ModelCatalog.defaultModelID,
            systemPrompt: """
            You are a creative/UX specialist. Design systems, component architecture, layout patterns, color, typography.
            Use ask_human to validate design decisions with the user.
            """,
            tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "publish_event", "ask_human", "recall_knowledge", "save_knowledge", "web_navigate", "web_screenshot", "web_read_text", "web_console", "web_inspect_head", "web_list_elements", "web_click", "web_type", "web_scroll"],
            denied: [],
            permissionMode: "acceptEdits",
            subscriptions: [],
            description: "Designer — UX, design systems, layouts",
            avatar: "🧙‍♂️",
            group: "Creative"
        ),
        "data": AgentTemplate(
            id: "catalog-data",
            name: "Data",
            model: ModelCatalog.defaultModelID,
            systemPrompt: """
            You are a data specialist. SQL, data pipelines, analytics, metrics, database design, migrations.
            Use propose_memory to document schema decisions and data models.
            """,
            tools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "message_agent", "publish_event", "propose_memory", "recall_knowledge", "save_knowledge"],
            denied: [],
            permissionMode: "acceptEdits",
            subscriptions: [],
            description: "Data — SQL, pipelines, analytics",
            avatar: "👁️",
            group: "Research"
        ),

        "copilot-critic": AgentTemplate(
            id: "catalog-copilot-critic",
            name: "Copilot Critic",
            model: "copilot-gpt-4o",
            systemPrompt: """
            You are a plan critic powered by GitHub Copilot. Your role is to review proposals from other agents \
            and provide structured feedback. Be concise, specific, and actionable.

            Always respond with valid JSON containing:
            - "verdict": "approve" or "revise"
            - "issues": array of specific problems found (empty array if approving)
            - "suggestions": array of improvement suggestions

            Focus on: feasibility, missing edge cases, security concerns, simpler alternatives, and potential risks.
            """,
            tools: [],
            denied: ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
            permissionMode: "plan",
            subscriptions: [],
            description: "Copilot-powered critic — reviews plans via structured debate",
            avatar: "🔍",
            group: "Review",
            runtimeKind: "copilot"
        ),
    ]

    static let predefined: [AgentTemplate] = [claude]
}
