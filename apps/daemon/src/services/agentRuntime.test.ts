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
});
