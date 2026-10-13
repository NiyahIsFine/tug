package push

import (
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"
)

func TestQueueLimitsAndRelease(t *testing.T) {
	receiver := newClient(nil, nil, 2, 5)
	if !receiver.enqueue([]byte("abc")) || receiver.enqueue([]byte("def")) || !receiver.enqueue([]byte("de")) || receiver.enqueue([]byte("")) {
		t.Fatal("queue byte/count boundaries are incorrect")
	}
	frame, exists := receiver.dequeue()
	if !exists || string(frame) != "abc" || !receiver.enqueue([]byte("f")) {
		t.Fatal("queue did not release byte budget or preserve order")
	}
	frame, _ = receiver.dequeue()
	if string(frame) != "de" {
		t.Fatal("queue ring order is incorrect")
	}
	receiver.close()
	if receiver.enqueue([]byte("g")) || receiver.count != 0 || receiver.bytes != 0 {
		t.Fatal("closed queue retains contents or accepts frames")
	}
	for _, retained := range receiver.frames {
		if retained != nil {
			t.Fatal("closed queue retains message references")
		}
	}
}

func TestSlowClientDoesNotBlockHealthyClient(t *testing.T) {
	registry := newHub(2, slog.New(slog.NewTextHandler(io.Discard, nil)))
	slow := newClient(nil, registry, 1, 32)
	healthy := newClient(nil, registry, 2, 32)
	registry.clients[slow] = struct{}{}
	registry.clients[healthy] = struct{}{}
	slow.enqueue([]byte("full"))
	online, queued, open := registry.broadcast([]byte("message"))
	if !open || online != 2 || queued != 1 || !slow.closed {
		t.Fatalf("incorrect slow-client handling: %d, %d, %v", online, queued, open)
	}
	frame, exists := healthy.dequeue()
	if !exists || string(frame) != "message" || len(registry.clients) != 1 {
		t.Fatal("healthy client was blocked or slow client not removed")
	}
	registry.closeAll()
	if _, _, open := registry.broadcast(nil); open || registry.reserve() {
		t.Fatal("closed hub accepts new work")
	}
}

func TestQueueConcurrentClose(t *testing.T) {
	receiver := newClient(nil, nil, 16, 1024)
	var workers sync.WaitGroup
	for index := 0; index < 8; index++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for attempt := 0; attempt < 1000; attempt++ {
				receiver.enqueue([]byte("frame"))
				receiver.dequeue()
			}
		}()
	}
	receiver.close()
	workers.Wait()
}

func TestRateLimiterWithControlledTime(t *testing.T) {
	start := time.Now()
	limiter := rateLimiter{rate: 2, burst: 4, tokens: 4, last: start}
	for index := 0; index < 4; index++ {
		if !limiter.allow(start) {
			t.Fatal("initial burst was not available")
		}
	}
	if limiter.allow(start) || !limiter.allow(start.Add(500*time.Millisecond)) || limiter.allow(start.Add(500*time.Millisecond)) {
		t.Fatal("limiter does not respect burst/refill")
	}
}
