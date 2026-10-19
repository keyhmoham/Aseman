package developer

import (
	"sort"
	"strings"
)

// MaxPrice refuses any provider dearer than this, in ledger units per 1M tokens.
type MaxPrice struct {
	Input  *float64 `json:"input,omitempty"`
	Output *float64 `json:"output,omitempty"`
}

// RouteOptions are how a request chooses among the providers that serve a model.
type RouteOptions struct {
	// Order lists providers to try first, in this order.
	Order []string `json:"order,omitempty"`
	// Only restricts the request to these providers.
	Only []string `json:"only,omitempty"`
	// Ignore never uses these providers.
	Ignore []string `json:"ignore,omitempty"`
	// AllowFallbacks (default true) lets the next provider answer when one fails.
	AllowFallbacks *bool `json:"allow_fallbacks,omitempty"`
	// Sort ranks the providers by "price", "latency" or "throughput".
	Sort     string    `json:"sort,omitempty"`
	MaxPrice *MaxPrice `json:"max_price,omitempty"`
}

// ConsoleRoute is RouteOptions as the console spells them (camelCase, with
// prices in ledger units).
type ConsoleRoute struct {
	Order          []string  `json:"order"`
	Only           []string  `json:"only"`
	Ignore         []string  `json:"ignore"`
	AllowFallbacks *bool     `json:"allowFallbacks"`
	Sort           string    `json:"sort"`
	MaxPrice       *MaxPrice `json:"maxPrice"`
}

// Options converts to the engine's.
func (c ConsoleRoute) Options() RouteOptions {
	return RouteOptions{Order: c.Order, Only: c.Only, Ignore: c.Ignore, AllowFallbacks: c.AllowFallbacks, Sort: c.Sort, MaxPrice: c.MaxPrice}
}

// Attempt is one provider the request will try.
type Attempt struct {
	Model    *CatalogModel
	Endpoint Endpoint
}

// Plan is the providers a request will try, in order.
type Plan struct {
	Attempts []Attempt
	Notes    []string
	Err      string
}

// ParseModelRef reads `google/gemini-3.8-flash:floor`: the model, and the sort
// the suffix stands for (`:floor` is cheapest, `:fast` is quickest).
func ParseModelRef(ref string) (id, sort string) {
	ref = strings.TrimSpace(ref)
	for suffix, by := range map[string]string{":floor": "price", ":fast": "latency"} {
		if strings.HasSuffix(ref, suffix) {
			return strings.TrimSuffix(ref, suffix), by
		}
	}
	return ref, ""
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func rank(eps []Endpoint, by string) []Endpoint {
	out := append([]Endpoint(nil), eps...)
	switch by {
	case "price":
		sort.SliceStable(out, func(i, j int) bool { return priceScore(out[i]) < priceScore(out[j]) })
	case "latency":
		sort.SliceStable(out, func(i, j int) bool { return latency(out[i]) < latency(out[j]) })
	case "throughput":
		sort.SliceStable(out, func(i, j int) bool { return throughput(out[i]) > throughput(out[j]) })
	}
	return out
}

func latency(e Endpoint) float64 {
	if e.Stats != nil && e.Stats.LatencyMs > 0 {
		return e.Stats.LatencyMs
	}
	return 1e18
}

func throughput(e Endpoint) float64 {
	if e.Stats != nil {
		return e.Stats.TokensPerSecond
	}
	return 0
}

// overPrice is whether an endpoint charges more than a cap allows.
func overPrice(e Endpoint, max *MaxPrice) bool {
	if max == nil {
		return false
	}
	for _, p := range e.Prices {
		if p.Label == "Input" && max.Input != nil && p.Units > *max.Input {
			return true
		}
		if p.Label == "Output" && max.Output != nil && p.Units > *max.Output {
			return true
		}
	}
	return false
}

// PlanRoute lists the providers a request will try: each model's own providers,
// filtered by only / ignore / max_price, ordered by `order`, then the sort, then
// the default, and cut to one when fallbacks are off. Fallback models follow,
// each routed the same way. A model nobody serves is skipped.
func PlanRoute(catalog []CatalogModel, model string, route RouteOptions, fallbacks []string) Plan {
	var plan Plan
	refs := append([]string{model}, fallbacks...)
	for i, ref := range refs {
		id, suffixSort := ParseModelRef(ref)
		entry := FindModel(catalog, id)
		if entry == nil {
			note := "Unknown model " + id + "."
			if i > 0 {
				note = "Unknown model " + id + ", skipped."
			}
			plan.Notes = append(plan.Notes, note)
			continue
		}
		by := route.Sort
		if by == "" {
			by = suffixSort
		}
		var pool []Endpoint
		for _, e := range entry.Endpoints {
			if len(route.Only) > 0 && !contains(route.Only, e.Provider) || contains(route.Ignore, e.Provider) || overPrice(e, route.MaxPrice) {
				continue
			}
			pool = append(pool, e)
		}
		ordered := rank(pool, by)
		if len(route.Order) > 0 {
			var first, rest []Endpoint
			for _, p := range route.Order {
				for _, e := range ordered {
					if e.Provider == p {
						first = append(first, e)
					}
				}
			}
			for _, e := range ordered {
				listed := false
				for _, f := range first {
					listed = listed || f.Provider == e.Provider
				}
				if !listed {
					rest = append(rest, e)
				}
			}
			ordered = append(first, rest...)
		} else if by == "" {
			var def, other []Endpoint
			for _, e := range ordered {
				if e.IsDefault {
					def = append(def, e)
				} else {
					other = append(other, e)
				}
			}
			ordered = append(def, other...)
		}
		if route.AllowFallbacks != nil && !*route.AllowFallbacks && len(ordered) > 1 {
			ordered = ordered[:1]
		}
		if len(ordered) == 0 {
			plan.Notes = append(plan.Notes, entry.ID+": no provider matches your routing options.")
		}
		for _, e := range ordered {
			plan.Attempts = append(plan.Attempts, Attempt{Model: entry, Endpoint: e})
		}
	}
	if len(plan.Attempts) == 0 {
		plan.Err = "No provider can serve this request with those options."
	}
	return plan
}
