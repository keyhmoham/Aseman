package vmm

import "context"

// TurnLLM is the metered OpenAI-compatible LLM endpoint of the current agent
// turn. Sandbox tools (OpenCode) use the same Token + BaseURL as the runtime
// so completions are gated and billed through serveChat → meter → billAgentTurn.
type TurnLLM struct {
	// Token is the turn bearer accepted by /deepagents/v1/llm/*.
	Token string
	// BaseURL is the OpenAI-compatible root (…/deepagents/v1/llm); clients
	// append /chat/completions and /models.
	BaseURL string
	// Model is the client-facing model id OpenCode should request. The gateway
	// rewrites it to the agent's admin-configured provider model.
	Model string
}

type turnLLMKey struct{}

func WithTurnLLM(ctx context.Context, llm TurnLLM) context.Context {
	return context.WithValue(ctx, turnLLMKey{}, llm)
}

func TurnLLMFrom(ctx context.Context) TurnLLM {
	llm, _ := ctx.Value(turnLLMKey{}).(TurnLLM)
	return llm
}
