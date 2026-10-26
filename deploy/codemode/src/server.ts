/**
 * Cloudflare Code Mode MCP for Aseman capabilities (apps, platform, timeline).
 *
 * Loads the space's OpenAPI from the Aseman node and runs model-written JS in
 * DynamicWorkerExecutor. codemode.request is forwarded to the node so auth
 * never enters the sandbox.
 */
import { DynamicWorkerExecutor } from "@cloudflare/codemode";
import { openApiMcpServer } from "@cloudflare/codemode/mcp";
import { createLegacyMcpHandler } from "agents/mcp";

export interface Env {
  LOADER: WorkerLoader;
  ASEMAN_ORIGIN: string;
}

async function loadSpec(origin: string, space: string, authorization: string): Promise<Record<string, unknown>> {
  const response = await fetch(`${origin.replace(/\/$/, "")}/tools/v1/codemode/openapi`, {
    headers: {
      Authorization: authorization,
      "X-Aseman-Space": space,
    },
  });
  if (!response.ok) {
    throw new Error(`Aseman OpenAPI failed: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as Record<string, unknown>;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    const authorization = request.headers.get("Authorization") ?? "";
    if (!authorization.startsWith("Bearer ")) {
      return new Response("Bearer token required (Aseman session)", { status: 401 });
    }
    const space =
      request.headers.get("X-Aseman-Space") ||
      url.searchParams.get("space") ||
      "";
    if (!space) {
      return new Response("X-Aseman-Space header or ?space= required", { status: 400 });
    }

    const origin = env.ASEMAN_ORIGIN || "http://localhost:8080";
    const server = openApiMcpServer({
      spec: await loadSpec(origin, space, authorization),
      executor: new DynamicWorkerExecutor({ loader: env.LOADER }),
      name: "aseman-codemode",
      version: "1.0.0",
      description:
        "Aseman capabilities via Cloudflare Code Mode. Paths: POST /apps/{slug}/{function}, /platform/{tool}, /timeline/{tool}.",
      request: async (options) => {
        if (!options.path.startsWith("/")) {
          throw new Error("API path must start with a slash");
        }
        const headers: Record<string, string> = {
          Authorization: authorization,
          "X-Aseman-Space": space,
          "Content-Type": "application/json",
        };
        const room = request.headers.get("X-Aseman-Room") || url.searchParams.get("room");
        if (room) headers["X-Aseman-Room"] = room;
        const response = await fetch(`${origin.replace(/\/$/, "")}/tools/v1/codemode/request`, {
          method: "POST",
          headers,
          body: JSON.stringify(options),
        });
        if (!response.ok) {
          throw new Error(`Aseman request failed: ${response.status} ${await response.text()}`);
        }
        if (response.status === 204) return null;
        const type = response.headers.get("Content-Type") ?? "";
        return type.includes("application/json") ? await response.json() : await response.text();
      },
    });

    return createLegacyMcpHandler(server, { route: "/mcp" })(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
