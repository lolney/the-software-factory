import { describe, expect, it } from "vitest";
import { DeterministicAgentRuntime } from "./agentRuntime.js";

describe("DeterministicAgentRuntime", () => {
  it("emits stable status, reasoning, tool, message events", async () => {
    const runtime = new DeterministicAgentRuntime();
    const events = await runtime.runTurn({
      sessionId: "sess_debug",
      agentId: "orchestrator",
      prompt: "please run QA",
      debugMode: true
    });

    expect(events.map((event) => event.type)).toEqual([
      "agent.status",
      "agent.reasoning",
      "agent.tool_call",
      "agent.tool_result",
      "agent.message",
      "agent.status"
    ]);
    expect(events[4]?.payload.text).toContain("Debug QA");
  });
});

describe("OpenAIAgentRuntime", () => {
  it("does not silently fall back to deterministic mode for unauthenticated non-debug runs", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    const original = process.env.OPENAI_API_KEY;
    delete process.env.OPENAI_API_KEY;
    try {
      await expect(new OpenAIAgentRuntime().runTurn({
        sessionId: "sess_live",
        agentId: "orchestrator",
        prompt: "run live",
        debugMode: false
      })).rejects.toThrow("OpenAI authentication is required");
    } finally {
      if (original) {
        process.env.OPENAI_API_KEY = original;
      }
    }
  });

  it("routes WHAM connections through the compatibility adapter with telemetry", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    const fetchCalls: Array<{ url: string; body: Record<string, unknown> }> = [];
    const fetchMock = async (url: string | URL | Request, init?: RequestInit) => {
      fetchCalls.push({ url: String(url), body: JSON.parse(String(init?.body)) });
      return new Response([
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "completed via wham" })}`,
        "",
        `data: ${JSON.stringify({ type: "response.completed", response: { usage: { input_tokens: 7, output_tokens: 3 } } })}`,
        "",
        "data: [DONE]",
        ""
      ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
    };

    const events = await new OpenAIAgentRuntime({ fetch: fetchMock as unknown as typeof fetch, timeoutMs: 1_000 }).runTurn({
      sessionId: "sess_wham",
      agentId: "implementor",
      prompt: "run live",
      debugMode: false,
      model: "gpt-5.4",
      reasoningEffort: "medium",
      openAI: {
        apiKey: "test-token",
        baseURL: "https://chatgpt.com/backend-api/wham",
        defaultHeaders: { "ChatGPT-Account-Id": "acct_123" }
      }
    });

    const message = events.find((event) => event.type === "agent.message");
    expect(fetchCalls).toHaveLength(1);
    expect(fetchCalls[0]?.url).toBe("https://chatgpt.com/backend-api/wham/responses");
    expect(fetchCalls[0]?.body.model).toBe("gpt-5.4");
    expect(fetchCalls[0]?.body.reasoning).toEqual({ effort: "medium" });
    expect(message?.payload.runtime).toBe("openai-wham");
    expect(message?.payload.text).toBe("completed via wham");
    expect(message?.payload.usage).toEqual({ input_tokens: 7, output_tokens: 3 });
    expect(message?.payload.attempts).toBe(1);
  });

  it("retries transient WHAM responses before returning normalized output", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    let attempts = 0;
    const fetchMock = async () => {
      attempts += 1;
      if (attempts === 1) {
        return new Response("busy", { status: 503 });
      }
      return new Response([
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "ok after retry" })}`,
        "",
        "data: [DONE]",
        ""
      ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
    };

    const events = await new OpenAIAgentRuntime({ fetch: fetchMock as unknown as typeof fetch, timeoutMs: 1_000 }).runTurn({
      sessionId: "sess_retry",
      agentId: "implementor",
      prompt: "run live",
      debugMode: false,
      openAI: {
        apiKey: "test-token",
        baseURL: "https://chatgpt.com/backend-api/wham"
      }
    });

    const message = events.find((event) => event.type === "agent.message");
    expect(attempts).toBe(2);
    expect(message?.payload.text).toBe("ok after retry");
    expect(message?.payload.attempts).toBe(2);
  });

  it("classifies WHAM token expiry as an authentication error", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    const fetchMock = async () => new Response(JSON.stringify({
      error: {
        message: "Provided authentication token is expired. Please try signing in again.",
        code: "token_expired"
      },
      status: 401
    }), { status: 401, headers: { "content-type": "application/json" } });

    await expect(new OpenAIAgentRuntime({ fetch: fetchMock as unknown as typeof fetch, timeoutMs: 1_000 }).runTurn({
      sessionId: "sess_auth_expired",
      agentId: "orchestrator",
      prompt: "run live",
      debugMode: false,
      openAI: {
        apiKey: "expired-token",
        baseURL: "https://chatgpt.com/backend-api/wham"
      }
    })).rejects.toMatchObject({
      name: "OpenAIAuthenticationError",
      status: 401,
      code: "token_expired"
    });
  });

  it("passes image attachments to WHAM responses input", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    let requestBody: Record<string, any> | undefined;
    const fetchMock = async (_url: string | URL | Request, init?: RequestInit) => {
      requestBody = JSON.parse(String(init?.body));
      return new Response([
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "image reviewed" })}`,
        "",
        "data: [DONE]",
        ""
      ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
    };

    await new OpenAIAgentRuntime({ fetch: fetchMock as unknown as typeof fetch, timeoutMs: 1_000 }).runTurn({
      sessionId: "sess_image",
      agentId: "ui_qa",
      prompt: "Review this screenshot",
      debugMode: false,
      openAI: {
        apiKey: "test-token",
        baseURL: "https://chatgpt.com/backend-api/wham"
      },
      imageAttachments: [{
        id: "img_test",
        name: "screenshot.png",
        mimeType: "image/png",
        dataBase64: "iVBORw0KGgo=",
        detail: "high"
      }]
    });

    const content = requestBody?.input?.[0]?.content;
    expect(content).toEqual([
      { type: "input_text", text: "Review this screenshot" },
      { type: "input_image", image_url: "data:image/png;base64,iVBORw0KGgo=", detail: "high" }
    ]);
  });

  it("does not retry caller-cancelled WHAM requests", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    let attempts = 0;
    const controller = new AbortController();
    const fetchMock = async (_url: string | URL | Request, init?: RequestInit) => {
      attempts += 1;
      controller.abort();
      init?.signal?.throwIfAborted();
      return new Response("unreachable", { status: 200 });
    };

    await expect(new OpenAIAgentRuntime({ fetch: fetchMock as unknown as typeof fetch, timeoutMs: 1_000 }).runTurn({
      sessionId: "sess_abort",
      agentId: "implementor",
      prompt: "run live",
      debugMode: false,
      openAI: {
        apiKey: "test-token",
        baseURL: "https://chatgpt.com/backend-api/wham"
      },
      signal: controller.signal
    })).rejects.toThrow();
    expect(attempts).toBe(1);
  });

  it("emits WHAM tool transcript events around tool side effects in causal order", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    const order: string[] = [];
    let requestIndex = 0;
    const fetchMock = async () => {
      requestIndex += 1;
      if (requestIndex === 1) {
        return new Response([
          `data: ${JSON.stringify({
            type: "response.output_item.done",
            item: {
              type: "function_call",
              call_id: "call_stop",
              name: "workflow_stop_self",
              arguments: JSON.stringify({
                reason: "done",
                artifact: "artifact",
                completedCriteria: ["criterion.done"]
              })
            }
          })}`,
          "",
          "data: [DONE]",
          ""
        ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
      }
      return new Response([
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "finished" })}`,
        "",
        "data: [DONE]",
        ""
      ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
    };

    const emittedEvents: string[] = [];
    const events = await new OpenAIAgentRuntime({ fetch: fetchMock as unknown as typeof fetch, timeoutMs: 1_000 }).runTurn({
      sessionId: "sess_wham_tools",
      agentId: "implementor",
      prompt: "finish your work",
      debugMode: false,
      openAI: {
        apiKey: "test-token",
        baseURL: "https://chatgpt.com/backend-api/wham"
      },
      workflowTools: {
        stopSelf: async () => {
          order.push("side-effect");
          return "stopped";
        }
      },
      emitEvent: async (event) => {
        if (event.type === "agent.tool_call" || event.type === "agent.tool_result") {
          const toolName = typeof event.payload.toolName === "string" ? event.payload.toolName : "unknown";
          order.push(`${event.type}:${toolName}`);
          emittedEvents.push(event.type);
        }
      }
    });

    expect(order).toEqual([
      "agent.tool_call:workflow_stop_self",
      "side-effect",
      "agent.tool_result:workflow_stop_self"
    ]);
    expect(events.map((event) => event.type)).not.toContain("agent.tool_call");
    expect(events.map((event) => event.type)).not.toContain("agent.tool_result");
    expect(emittedEvents).toEqual(["agent.tool_call", "agent.tool_result"]);
  });

  it("does not emit duplicate WHAM transcript rows for engine-logged workspace tools", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    let requestIndex = 0;
    const fetchMock = async () => {
      requestIndex += 1;
      if (requestIndex === 1) {
        return new Response([
          `data: ${JSON.stringify({
            type: "response.output_item.done",
            item: {
              type: "function_call",
              call_id: "call_write",
              name: "workspace_write_file",
              arguments: JSON.stringify({ path: "hello.txt", content: "hello" })
            }
          })}`,
          "",
          "data: [DONE]",
          ""
        ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
      }
      return new Response([
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "done" })}`,
        "",
        "data: [DONE]",
        ""
      ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
    };

    const emittedEvents: string[] = [];
    const sideEffects: string[] = [];
    const events = await new OpenAIAgentRuntime({ fetch: fetchMock as unknown as typeof fetch, timeoutMs: 1_000 }).runTurn({
      sessionId: "sess_wham_dedupe",
      agentId: "implementor",
      prompt: "write a file",
      debugMode: false,
      openAI: {
        apiKey: "test-token",
        baseURL: "https://chatgpt.com/backend-api/wham"
      },
      workflowTools: {
        writeWorkspaceFile: async (relativePath, content) => {
          sideEffects.push(`${relativePath}:${content}`);
          return "Edited hello.txt +1 -0.";
        }
      },
      emitEvent: async (event) => {
        if (event.type === "agent.tool_call" || event.type === "agent.tool_result") {
          emittedEvents.push(`${event.type}:${String(event.payload.toolName ?? "")}`);
        }
      }
    });

    expect(sideEffects).toEqual(["hello.txt:hello"]);
    expect(emittedEvents).toEqual([]);
    expect(events.map((event) => event.type)).not.toContain("agent.tool_call");
    expect(events.map((event) => event.type)).not.toContain("agent.tool_result");
  });

  it("does not emit duplicate WHAM transcript rows for engine-logged command tools", async () => {
    const { OpenAIAgentRuntime } = await import("./agentRuntime.js");
    let requestIndex = 0;
    const fetchMock = async () => {
      requestIndex += 1;
      if (requestIndex === 1) {
        return new Response([
          `data: ${JSON.stringify({
            type: "response.output_item.done",
            item: {
              type: "function_call",
              call_id: "call_command",
              name: "workspace_run_command",
              arguments: JSON.stringify({ command: "node", args: ["--version"], cwd: null })
            }
          })}`,
          "",
          "data: [DONE]",
          ""
        ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
      }
      return new Response([
        `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "done" })}`,
        "",
        "data: [DONE]",
        ""
      ].join("\n"), { status: 200, headers: { "content-type": "text/event-stream" } });
    };

    const emittedEvents: string[] = [];
    const sideEffects: string[] = [];
    const events = await new OpenAIAgentRuntime({ fetch: fetchMock as unknown as typeof fetch, timeoutMs: 1_000 }).runTurn({
      sessionId: "sess_wham_command_dedupe",
      agentId: "qa",
      prompt: "run tests",
      debugMode: false,
      openAI: {
        apiKey: "test-token",
        baseURL: "https://chatgpt.com/backend-api/wham"
      },
      workflowTools: {
        runWorkspaceCommand: async (command, args = [], cwd) => {
          sideEffects.push(`${command} ${args.join(" ")} ${cwd ?? "."}`);
          return "exitCode: 0";
        }
      },
      emitEvent: async (event) => {
        if (event.type === "agent.tool_call" || event.type === "agent.tool_result") {
          emittedEvents.push(`${event.type}:${String(event.payload.toolName ?? "")}`);
        }
      }
    });

    expect(sideEffects).toEqual(["node --version ."]);
    expect(emittedEvents).toEqual([]);
    expect(events.map((event) => event.type)).not.toContain("agent.tool_call");
    expect(events.map((event) => event.type)).not.toContain("agent.tool_result");
  });
});
