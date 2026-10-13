package network

// Tunnel is a protocol adapter's authorized duplex transport request. Domain
// handlers choose the destination only after their resource access checks.
type Tunnel struct {
	Protocol string
	Target   string
	Header   map[string]string
}
