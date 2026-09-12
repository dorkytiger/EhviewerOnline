// Package events provides a small fan-out hub for server-sent events.
//
// The design goal is narrow: turn "the index changed" into a message that
// connected clients can act on, without letting a slow or dead client affect
// anything else.
//
// Two properties matter more than throughput here:
//
//   - **A publish never blocks.** Each subscriber gets a buffered channel and a
//     drop-on-full send. A client that stops reading loses events rather than
//     stalling the rebuild that is trying to publish.
//   - **A publish never panics.** The obvious implementation — close the
//     subscriber's channel on disconnect and send from the publisher — races:
//     a publisher between its map lookup and its send will hit a closed
//     channel and panic, and that panic happens on the publishing goroutine
//     (an HTTP handler), so it can take down an unrelated request. Instead the
//     payload channel is never closed; disconnect is signalled on a separate
//     `done` channel that is closed exactly once, and the publisher selects on
//     it. A panicking fan-out is a strictly worse failure than a dropped
//     event, and this design makes it structurally impossible.
package events

import (
	"encoding/json"
	"sync"
	"sync/atomic"
)

// Event names, also used as the SSE `event:` field.
const (
	// EventHello is sent once on connect so a client can confirm the stream is
	// live rather than inferring it from silence.
	EventHello = "hello"
	// EventIndexChanged reports which galleries changed in a rebuild.
	EventIndexChanged = "index_changed"
	// EventReady is reserved for a future "index loaded" notification.
	EventReady = "ready"
)

// DefaultBuffer is the per-subscriber queue depth.
//
// Small on purpose: the messages are deltas that supersede each other, so a
// client that falls far behind is better served by one full refresh than by a
// long backlog of partial ones.
const DefaultBuffer = 16

// Event is the wire payload. It is deliberately JSON-serialisable and flat, so
// the SSE writer never has to think about structure.
type Event struct {
	// Name is the SSE event name.
	Name string `json:"-"`
	// IndexAtMS is when the index that produced this event was built.
	IndexAtMS int64 `json:"index_at_ms"`
	// SnapshotAtMS is the metadata snapshot timestamp, so a client can tell
	// that the metadata moved rather than only the files.
	SnapshotAtMS int64 `json:"snapshot_at_ms"`
	// Galleries is the total count after the change.
	Galleries int `json:"galleries"`
	// Added, Changed and Removed list the affected gids.
	//
	// Bounded by MaxGIDs: a first index or a bulk sync can touch everything,
	// and a 100k-element array on every event would be worse than useless. When
	// the list is truncated, Truncated is set and the client should do a full
	// refetch instead of trying to apply a partial delta.
	Added     []int64 `json:"added,omitempty"`
	Changed   []int64 `json:"changed,omitempty"`
	Removed   []int64 `json:"removed,omitempty"`
	Truncated bool    `json:"truncated,omitempty"`
	// Reason is a short human-readable note, for logs and diagnostics.
	Reason string `json:"reason,omitempty"`
}

// MaxGIDs caps how many ids an event carries before it is marked truncated.
const MaxGIDs = 512

// Marshal renders the event as the `data:` line payload.
func (e Event) Marshal() ([]byte, error) {
	// The name is carried by the `event:` field, so it is excluded from the
	// JSON body by the `json:"-"` tag.
	return json.Marshal(e)
}

type subscriber struct {
	ch   chan Event
	done chan struct{}
	once sync.Once
}

// Hub fans events out to connected subscribers.
type Hub struct {
	mu     sync.RWMutex
	subs   map[*subscriber]struct{}
	closed atomic.Bool

	// dropped counts events discarded because a subscriber's queue was full.
	dropped atomic.Int64
}

// NewHub creates an empty hub.
func NewHub() *Hub {
	return &Hub{subs: make(map[*subscriber]struct{})}
}

// Subscription is one connected client's stream.
type Subscription struct {
	hub  *Hub
	self *subscriber
}

// C returns the channel of events. It is never closed, so a receiver should
// also select on Done.
func (s *Subscription) C() <-chan Event { return s.self.ch }

// Done is closed when the subscription is closed. It exists so a receiver can
// distinguish "no event right now" from "this stream is finished".
func (s *Subscription) Done() <-chan struct{} { return s.self.done }

// Close ends the subscription. It is safe to call more than once and from any
// goroutine, which matters because both the SSE handler's defer and the hub's
// shutdown path call it.
func (s *Subscription) Close() {
	if s.hub == nil || s.self == nil {
		return
	}
	s.hub.mu.Lock()
	delete(s.hub.subs, s.self)
	s.hub.mu.Unlock()
	s.self.once.Do(func() { close(s.self.done) })
}

// Subscribe registers a new subscriber.
func (h *Hub) Subscribe() *Subscription {
	return h.SubscribeBuffer(DefaultBuffer)
}

// SubscribeBuffer registers a subscriber with a specific queue depth.
func (h *Hub) SubscribeBuffer(depth int) *Subscription {
	if depth <= 0 {
		depth = DefaultBuffer
	}
	sub := &subscriber{
		ch:   make(chan Event, depth),
		done: make(chan struct{}),
	}
	if h.closed.Load() {
		// The hub is shutting down; hand back a subscription that immediately
		// reports itself finished rather than one that silently never fires.
		sub.once.Do(func() { close(sub.done) })
		return &Subscription{self: sub}
	}
	h.mu.Lock()
	h.subs[sub] = struct{}{}
	h.mu.Unlock()
	return &Subscription{hub: h, self: sub}
}

// Broadcast delivers an event to every subscriber.
//
// It never blocks and never panics: a full queue drops the event, and a
// concurrent Close is handled by selecting on Done.
func (h *Hub) Broadcast(e Event) {
	h.mu.RLock()
	if len(h.subs) == 0 {
		h.mu.RUnlock()
		return
	}
	targets := make([]*subscriber, 0, len(h.subs))
	for s := range h.subs {
		targets = append(targets, s)
	}
	h.mu.RUnlock()

	for _, s := range targets {
		select {
		case <-s.done:
			// Already closed; skip rather than send.
			continue
		default:
		}
		select {
		case s.ch <- e:
		case <-s.done:
		default:
			// The subscriber is not keeping up. Dropping is the correct
			// behaviour: the alternative is stalling the publisher, which is a
			// rebuild.
			h.dropped.Add(1)
		}
	}
}

// Subscribers reports the number of connected clients.
func (h *Hub) Subscribers() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.subs)
}

// Dropped reports how many events were discarded because of slow subscribers.
func (h *Hub) Dropped() int64 { return h.dropped.Load() }

// Close disconnects every subscriber and rejects new ones.
//
// The payload channels are intentionally left unclosed: a receiver stops when
// Done fires. Closing them here would reintroduce exactly the send-on-closed
// race the design avoids.
func (h *Hub) Close() {
	h.closed.Store(true)
	h.mu.Lock()
	subs := make([]*subscriber, 0, len(h.subs))
	for s := range h.subs {
		subs = append(subs, s)
	}
	h.subs = make(map[*subscriber]struct{})
	h.mu.Unlock()

	for _, s := range subs {
		s.once.Do(func() { close(s.done) })
	}
}
