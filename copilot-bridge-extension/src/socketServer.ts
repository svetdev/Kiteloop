import * as net from "net";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import { BridgeRequest } from "./protocol";
import { CopilotBridge } from "./copilotBridge";

export class SocketServer {
  private server: net.Server | null = null;
  private bridge: CopilotBridge;
  private socketPath: string;

  constructor(bridge: CopilotBridge, socketPath?: string) {
    this.bridge = bridge;
    this.socketPath = socketPath ?? path.join(os.homedir(), ".kiteloop", "copilot-bridge.sock");
  }

  start(): void {
    const dir = path.dirname(this.socketPath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }

    if (fs.existsSync(this.socketPath)) {
      fs.unlinkSync(this.socketPath);
    }

    this.server = net.createServer((socket) => this.handleConnection(socket));
    this.server.listen(this.socketPath, () => {
      console.log(`Kiteloop Copilot bridge listening on ${this.socketPath}`);
    });

    this.server.on("error", (err) => {
      console.error("Socket server error:", err.message);
    });
  }

  stop(): void {
    this.server?.close();
    this.server = null;
    if (fs.existsSync(this.socketPath)) {
      fs.unlinkSync(this.socketPath);
    }
  }

  private handleConnection(socket: net.Socket): void {
    let buffer = "";

    socket.on("data", (data) => {
      buffer += data.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        if (line.trim()) {
          this.handleRequest(socket, line.trim());
        }
      }
    });

    socket.on("error", (err) => {
      console.error("Socket connection error:", err.message);
    });
  }

  private async handleRequest(socket: net.Socket, rawLine: string): Promise<void> {
    let request: BridgeRequest;
    try {
      request = JSON.parse(rawLine);
    } catch {
      this.writeLine(socket, { id: "unknown", type: "error", message: "Invalid JSON" });
      return;
    }

    const { id, type } = request;

    if (type === "ping") {
      try {
        const models = await this.bridge.getAvailableModels();
        this.writeLine(socket, { id, type: "pong", models });
      } catch (err: any) {
        this.writeLine(socket, { id, type: "error", message: err.message });
      }
      return;
    }

    if (type === "chat") {
      const { messages, model, maxTokens } = request;
      if (!messages || messages.length === 0) {
        this.writeLine(socket, { id, type: "error", message: "No messages provided" });
        return;
      }

      try {
        const fullText = await this.bridge.sendChat(
          messages,
          model,
          maxTokens,
          (chunk) => {
            this.writeLine(socket, { id, type: "delta", content: chunk });
          }
        );
        this.writeLine(socket, { id, type: "done", content: fullText });
      } catch (err: any) {
        this.writeLine(socket, { id, type: "error", message: err.message ?? "Unknown error" });
      }
      return;
    }

    this.writeLine(socket, { id, type: "error", message: `Unknown request type: ${type}` });
  }

  private writeLine(socket: net.Socket, obj: object): void {
    try {
      socket.write(JSON.stringify(obj) + "\n");
    } catch {
      // Socket may have closed
    }
  }
}
