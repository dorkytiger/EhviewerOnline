package events

import (
	"encoding/json"
	"sync"
	"testing"
	"time"
)

func TestBroadcastReachesEverySubscriber(t *testing.T) {
	hub := NewHub()
	defer hub.Close()

	a := hub.Subscribe()
	defer a.Close()
	b := hub.Subscribe()
	defer b.Close()

	if got := hub.Subscribers(); got != 2 {
		t.Fatalf("subscribers: got %d, want 2", got)
	}

	hub.Broadcast(Event{Galleries: 7, Reason: "test"})

	for name, sub := range map[string]*Subscription{"a": a, "b": b} {
		select {
		case got := <-sub.C():
			if got.Galleries != 7 || got.Reason != "test" {
				t.Errorf("%s: got %+v", name, got)
			}
		case <-time.After(time.Second):
			t.Errorf("%s: no event delivered", name)
		}
	}
}

// A subscriber that stops reading must not stall the publisher. This is the
// property that keeps a rebuild from being held hostage by one dead client.
func TestBroadcastNeverBlocksOnAFullQueue(t *testing.T) {
	hub := NewHub()
	defer hub.Close()

	sub := hub.SubscribeBuffer(2)
	defer sub.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 100; i++ {
			hub.Broadcast(Event{Galleries: i})
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Broadcast blocked on a subscriber that is not reading")
	}

	// The queue holds its capacity, and the rest were dropped rather than
	// queued.
	if got := len(sub.C()); got != 2 {
		t.Errorf("queued events: got %d, want the 2-deep capacity", got)
	}
	if hub.Dropped() == 0 {
		t.Error("dropped counter should record the overflow")
	}
}

// Broadcasting while a subscriber disconnects is the race the design exists to
// avoid: the obvious implementation sends on a channel that Close just closed.
// It must not panic, and it must not lose the other subscribers' events.
func TestBroadcastDuringCloseDoesNotPanic(t *testing.T) {
	for attempt := 0; attempt < 8; attempt++ {
		hub := NewHub()
		steady := hub.Subscribe()
		churn := hub.Subscribe()

		var wg sync.WaitGroup

		// Publisher.
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				hub.Broadcast(Event{Galleries: i})
			}
		}()

		// Subscriber churning in and out on the same hub.
		wg.Add(1)
		go func() {
			defer wg.Done()
			churn.Close()
			for i := 0; i < 20; i++ {
				s := hub.Subscribe()
				s.Close()
			}
		}()

		// A reader on the steady subscriber, so its queue drains and the
		// publisher actually exercises the send path.
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-steady.C():
				case <-steady.Done():
					return
				case <-time.After(500 * time.Millisecond):
					return
				}
			}
		}()

		wg.Wait()
		steady.Close()
		hub.Close()
	}
}

// Close must be idempotent: both the SSE handler's defer and the shutdown path
// call it.
func TestSubscriptionCloseIsIdempotent(t *testing.T) {
	hub := NewHub()
	defer hub.Close()

	sub := hub.Subscribe()
	sub.Close()
	sub.Close()
	sub.Close()

	if got := hub.Subscribers(); got != 0 {
		t.Errorf("subscribers after close: got %d, want 0", got)
	}
	select {
	case <-sub.Done():
	default:
		t.Error("Done should be closed after Close")
	}
}

// Closing the hub must release every subscriber, or a shutdown would leave
// handlers parked forever.
func TestHubCloseReleasesSubscribers(t *testing.T) {
	hub := NewHub()
	a := hub.Subscribe()
	b := hub.Subscribe()

	hub.Close()

	for name, sub := range map[string]*Subscription{"a": a, "b": b} {
		select {
		case <-sub.Done():
		case <-time.After(time.Second):
			t.Errorf("%s: Close did not signal Done", name)
		}
	}
	if got := hub.Subscribers(); got != 0 {
		t.Errorf("subscribers after hub close: got %d, want 0", got)
	}

	// A subscription created after shutdown must report itself finished rather
	// than hanging a handler that will never receive anything.
	late := hub.Subscribe()
	select {
	case <-late.Done():
	default:
		t.Error("a subscription created after Close should already be done")
	}
}

// Broadcast with no subscribers must be a no-op rather than a nil panic.
func TestBroadcastWithoutSubscribers(t *testing.T) {
	hub := NewHub()
	defer hub.Close()
	hub.Broadcast(Event{Galleries: 1})
}

func TestEventMarshalOmitsTheName(t *testing.T) {
	// The name travels in the SSE `event:` field, so duplicating it in the JSON
	// body would be redundant and would invite the two to disagree.
	raw, err := Event{Name: EventIndexChanged, Galleries: 3}.Marshal()
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if _, present := decoded["name"]; present {
		t.Error("the name must not appear in the JSON body")
	}
	if decoded["galleries"] != float64(3) {
		t.Errorf("galleries: got %v", decoded["galleries"])
	}
}

func TestEventOmitsEmptyIDLists(t *testing.T) {
	// An event that only changes the total should not carry three empty arrays.
	raw, err := Event{Galleries: 1}.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"added", "changed", "removed"} {
		if json.Valid(raw) && contains(string(raw), `"`+field+`"`) {
			t.Errorf("empty %s should be omitted, got %s", field, raw)
		}
	}
}

func contains(haystack, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}
