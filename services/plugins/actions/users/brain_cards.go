package users

import (
	"context"
	"fmt"
	"strings"
	"sync"
)

// Cards: what Aseman shows under an answer when words are not the best way: a room it made or points to
// (tap to open it), a small chart. They are stored with the answer, in the same sealed field as its proposal
// (brainProposal.Cards), and drawn by the app (BrainCards.tsx). A card carries no authority: opening a room is
// the app's own navigation, checked like any other.

const (
	cardRoom  = "room"
	cardChart = "chart"

	maxCards       = 6
	maxChartPoints = 12
)

// brainCard is one card.
type brainCard struct {
	Type     string      `json:"type"`
	ID       string      `json:"id,omitempty"` // a room's id
	Title    string      `json:"title"`
	Subtitle string      `json:"subtitle,omitempty"`
	Unit     string      `json:"unit,omitempty"`   // a chart's unit ("credits", "messages")
	Points   []cardPoint `json:"points,omitempty"` // a chart's bars
}

type cardPoint struct {
	Label string  `json:"label"`
	Value float64 `json:"value"`
}

// cardBox collects the cards one answer (or one confirmed proposal) makes.
type cardBox struct {
	mu    sync.Mutex
	cards []brainCard
}

func (b *cardBox) add(c brainCard) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.cards) < maxCards {
		b.cards = append(b.cards, c)
	}
}

func (b *cardBox) list() []brainCard {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]brainCard(nil), b.cards...)
}

type cardKey struct{}

func withCards(ctx context.Context, b *cardBox) context.Context {
	return context.WithValue(ctx, cardKey{}, b)
}

// addCard shows a card under the answer being made; a tool run outside one has nowhere to show it.
func addCard(ctx context.Context, c brainCard) {
	if b, _ := ctx.Value(cardKey{}).(*cardBox); b != nil {
		b.add(c)
	}
}

// chartCard checks the points a model gave for a chart.
func chartCard(title, unit string, raw []any) (brainCard, error) {
	card := brainCard{Type: cardChart, Title: clip(strings.TrimSpace(title), 80), Unit: clip(strings.TrimSpace(unit), 20)}
	for _, p := range raw {
		m, ok := p.(map[string]any)
		if !ok {
			continue
		}
		label, _ := m["label"].(string)
		value, ok := m["value"].(float64)
		if label = strings.TrimSpace(label); label == "" || !ok {
			continue
		}
		card.Points = append(card.Points, cardPoint{Label: clip(label, 24), Value: value})
		if len(card.Points) == maxChartPoints {
			break
		}
	}
	if card.Title == "" || len(card.Points) < 2 {
		return brainCard{}, fmt.Errorf("a chart needs a title and at least two points, each with a label and a number")
	}
	return card, nil
}

type noteKey struct{}

// withNote says which note the work being done is an answer to (a confirmed proposal's, its reply_to).
func withNote(ctx context.Context, note string) context.Context {
	return context.WithValue(ctx, noteKey{}, note)
}

func noteOf(ctx context.Context) string {
	v, _ := ctx.Value(noteKey{}).(string)
	return v
}
