package surface

// ValidateProps checks required props and child references (A2UI catalog-style).
// Prefer ValidateCatalogSchema; this name is kept for call sites.
func ValidateProps(components []map[string]any) []Issue {
	return ValidateCatalogSchema(components)
}
