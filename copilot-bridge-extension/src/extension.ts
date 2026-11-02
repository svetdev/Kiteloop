import * as vscode from "vscode";
import { CopilotBridge } from "./copilotBridge";
import { SocketServer } from "./socketServer";

let server: SocketServer | null = null;

export function activate(context: vscode.ExtensionContext): void {
  const bridge = new CopilotBridge();
  server = new SocketServer(bridge);
  server.start();

  const statusItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Right,
    100
  );
  statusItem.text = "$(plug) Kiteloop Bridge";
  statusItem.tooltip = "Kiteloop Copilot Bridge is active";
  statusItem.show();
  context.subscriptions.push(statusItem);

  context.subscriptions.push({
    dispose: () => {
      server?.stop();
      server = null;
    },
  });

  console.log("Kiteloop Copilot Bridge extension activated");
}

export function deactivate(): void {
  server?.stop();
  server = null;
}
