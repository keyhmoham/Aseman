// Tradera's plugin in every agent project (see ../workspace.py).
//
// Model calls go to the runtime's relay; each names the OpenCode session and
// agent it is for, so the relay tells the agent's own calls (its turn's system
// prompt, guard and budget apply) from OpenCode's own work on the session —
// compacting the conversation — and from a harness subagent's, which keep
// their own prompts.
export const TraderaSession = async () => ({
  "chat.headers": async (
    input: { sessionID: string; agent?: string | { name?: string } },
    output: { headers: Record<string, string> },
  ) => {
    output.headers["X-Tradera-Session"] = input.sessionID
    const agent = typeof input.agent === "string" ? input.agent : input.agent?.name
    if (agent) output.headers["X-Tradera-Agent"] = agent
  },
})
