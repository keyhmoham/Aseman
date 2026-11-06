// Package tenancy is how product surfaces stay isolated across platforms
// on one Aseman node. The empty platform id is main Aseman. A platform with
// MainAccess (granted only by the node admin) may see main Aseman entities,
// and main Aseman users may see that platform's — platforms never see each
// other through the bridge.
package tenancy

// Main is the shared Aseman environment (no platform).
const Main = ""

// Sees reports whether a viewer whose home is viewerPlatform may observe an
// entity that belongs to entityPlatform. bridged[id] is true when that
// platform has been granted MainAccess by the node admin.
func Sees(viewerPlatform, entityPlatform string, bridged map[string]bool) bool {
	if viewerPlatform == entityPlatform {
		return true
	}
	if viewerPlatform == Main && entityPlatform != Main && bridged[entityPlatform] {
		return true
	}
	if entityPlatform == Main && viewerPlatform != Main && bridged[viewerPlatform] {
		return true
	}
	return false
}

// Same reports whether two ids name the same environment (including both main).
func Same(a, b string) bool { return a == b }
