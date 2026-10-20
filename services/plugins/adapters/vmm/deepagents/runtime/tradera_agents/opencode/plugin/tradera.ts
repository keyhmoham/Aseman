// Tradera's plugin in every agent project (see ../workspace.py).
//
// Model calls go to the runtime's relay; each names the OpenCode session it is
// for, so the relay tells the agent's own session (its turn's system prompt,
// guard and budget apply) from a harness subagent's (which keeps its own).
export const TraderaSession = async () => ({
  "chat.headers": async (input: { sessionID: string }, output: { headers: Record<string, string> }) => {
    output.headers["X-Tradera-Session"] = input.sessionID
  },
})
