import * as vscode from "vscode";

export class CopilotBridge {
  async getAvailableModels(): Promise<string[]> {
    const models = await vscode.lm.selectChatModels();
    return models.map((m) => m.id);
  }

  async sendChat(
    messages: Array<{ role: string; content: string }>,
    modelFamily?: string,
    maxTokens?: number,
    onDelta?: (chunk: string) => void
  ): Promise<string> {
    const selector: vscode.LanguageModelChatSelector = modelFamily
      ? { family: modelFamily }
      : {};
    const models = await vscode.lm.selectChatModels(selector);
    if (models.length === 0) {
      const allModels = await vscode.lm.selectChatModels();
      if (allModels.length === 0) {
        throw new Error("No language models available via Copilot");
      }
      models.push(allModels[0]);
    }

    const model = models[0];
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
    return fullText;
  }
}
