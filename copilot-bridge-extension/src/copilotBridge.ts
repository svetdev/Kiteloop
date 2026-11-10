import * as vscode from "vscode";

/** A finished chat: the text, and the model that produced it. */
export interface ChatResult {
  content: string;
  model: string;
  vendor: string;
  family: string;
}

export class CopilotBridge {
  async getAvailableModels(): Promise<string[]> {
    const models = await vscode.lm.selectChatModels();
    return models.map((m) => m.id);
  }

  /**
   * The model a request names, or Copilot's first when it names none.
   *
   * A name is matched as a family (`gpt-4o`) and then as an id — `ping` lists
   * ids, so whatever it printed is accepted here. A name that matches neither
   * is an error naming what is available: it used to fall back to the first
   * model VS Code lists, and nothing said which model had answered.
   */
  async resolveModel(requested?: string): Promise<vscode.LanguageModelChat> {
    const name = requested?.trim();
    if (!name) {
      const all = await vscode.lm.selectChatModels();
      if (all.length === 0) {
        throw new Error("No language models available via Copilot");
      }
      return all[0];
    }
    const byFamily = await vscode.lm.selectChatModels({ family: name });
    if (byFamily.length > 0) {
      return byFamily[0];
    }
    const byId = await vscode.lm.selectChatModels({ id: name });
    if (byId.length > 0) {
      return byId[0];
    }
    const available = (await vscode.lm.selectChatModels()).map((m) => m.id);
    throw new Error(
      `Unknown Copilot model "${name}" — no model has that family or id. ` +
        (available.length > 0
          ? `Available: ${available.join(", ")}`
          : "No language models are available via Copilot")
    );
  }

  async sendChat(
    messages: Array<{ role: string; content: string }>,
    modelName?: string,
    maxTokens?: number,
    onDelta?: (chunk: string) => void
  ): Promise<ChatResult> {
    const model = await this.resolveModel(modelName);
    const chatMessages = messages.map((msg) => {
      if (msg.role === "system" || msg.role === "user") {
        return vscode.LanguageModelChatMessage.User(msg.content);
      }
      return vscode.LanguageModelChatMessage.Assistant(msg.content);
    });

    const options: vscode.LanguageModelChatRequestOptions = {};
    if (maxTokens) {
      (options as any).maxTokens = maxTokens;
    }

    const response = await model.sendRequest(
      chatMessages,
      options,
      new vscode.CancellationTokenSource().token
    );

    let fullText = "";
    for await (const chunk of response.text) {
      fullText += chunk;
      onDelta?.(chunk);
    }
    return { content: fullText, model: model.id, vendor: model.vendor, family: model.family };
  }
}
