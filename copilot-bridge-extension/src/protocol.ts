export interface BridgeRequest {
  id: string;
  type: "chat" | "ping";
  model?: string;
  messages?: Array<{ role: string; content: string }>;
  maxTokens?: number;
}

export interface DeltaResponse {
  id: string;
  type: "delta";
  content: string;
}

export interface DoneResponse {
  id: string;
  type: "done";
  content: string;
}

export interface ErrorResponse {
  id: string;
  type: "error";
  message: string;
}

export interface PongResponse {
  id: string;
  type: "pong";
  models: string[];
}

export type BridgeResponse =
  | DeltaResponse
  | DoneResponse
  | ErrorResponse
  | PongResponse;
