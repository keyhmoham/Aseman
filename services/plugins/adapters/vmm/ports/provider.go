package vmm

// ProviderConfig is a resolved LLM provider endpoint: the OpenAI-compatible
// base URL, API key and the model to call.
type ProviderConfig struct {
	Kind    string
	BaseURL string
	APIKey  string
	Model   string
	// ContextWindow is the model's input window in tokens (0 = unknown).
	ContextWindow int
	// ImageModel / ImagePrice are set when resolving an image provider.
	ImageModel string
	ImagePrice float64
	// InputPrice / OutputPrice (credits per 1M tokens) are set when resolving
	// the decision model, whose usage is priced apart from the agent's model.
	InputPrice  float64
	OutputPrice float64
	// AutoApprove is the decision model's permission to approve low-risk
	// tool calls that otherwise wait on a person.
	AutoApprove bool
	// OwnerID is the account that owns the provider's API key: what the model
	// costs is paid to it (set when resolving the memory models).
	OwnerID string
}
