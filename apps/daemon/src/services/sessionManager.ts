import type { DaemonRequest, SessionEvent } from "@multiagent/shared";

export class SessionManager {
  private publish: (event: SessionEvent) => void = () => {};

  constructor(private readonly options: { sessionsRoot: string }) {}

  setPublisher(publish: (event: SessionEvent) => void) {
    this.publish = publish;
  }

  async handle(request: DaemonRequest): Promise<unknown> {
    switch (request.method) {
      case "listSessions":
        return { sessionsRoot: this.options.sessionsRoot, sessions: [] };
      case "createSession":
        return {
          sessionId: `sess_${crypto.randomUUID()}`,
          prompt: request.params.prompt,
          workspaceRoot: request.params.workspaceRoot ?? process.cwd()
        };
      case "subscribeEvents":
      case "getSnapshot":
      case "sendMessage":
      case "pauseAgent":
      case "resumeAgent":
      case "cancelAgent":
      case "ackClientEvent":
        return { accepted: true };
    }
  }

  emit(event: SessionEvent) {
    this.publish(event);
  }
}
