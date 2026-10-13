package config

type ModalConfig struct {
	TokenID     string `json:"token_id" yaml:"token_id"`
	TokenSecret string `json:"token_secret" yaml:"token_secret"`
	// Environment is the Modal environment (e.g. "dev") this node's sandboxes,
	// volumes and costs live in; empty uses the profile default.
	Environment string `json:"environment" yaml:"environment"`
}
