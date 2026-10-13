package push

import (
	"log/slog"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const writeTimeout = 10 * time.Second

type hub struct {
	mutex        sync.Mutex
	clients      map[*client]struct{}
	reservations int
	maximum      int
	closed       bool
	workers      sync.WaitGroup
	logger       *slog.Logger
}

type client struct {
	connection *websocket.Conn
	hub        *hub
	mutex      sync.Mutex
	frames     [][]byte
	head       int
	count      int
	bytes      int
	byteLimit  int
	notify     chan struct{}
	stopped    chan struct{}
	closeOnce  sync.Once
	closed     bool
}

func newHub(maximum int, logger *slog.Logger) *hub {
	return &hub{clients: make(map[*client]struct{}), maximum: maximum, logger: logger}
}

func (registry *hub) reserve() bool {
	registry.mutex.Lock()
	defer registry.mutex.Unlock()
	if registry.closed || len(registry.clients)+registry.reservations >= registry.maximum {
		return false
	}
	registry.reservations++
	return true
}

func (registry *hub) release() {
	registry.mutex.Lock()
	registry.reservations--
	registry.mutex.Unlock()
}

func (registry *hub) attach(receiver *client) bool {
	registry.mutex.Lock()
	defer registry.mutex.Unlock()
	if registry.closed {
		return false
	}
	registry.clients[receiver] = struct{}{}
	registry.workers.Add(2)
	go receiver.read()
	go receiver.write()
	return true
}

func (registry *hub) remove(receiver *client) {
	registry.mutex.Lock()
	delete(registry.clients, receiver)
	registry.mutex.Unlock()
}

func (registry *hub) broadcast(frame []byte) (int, int, bool) {
	registry.mutex.Lock()
	if registry.closed {
		registry.mutex.Unlock()
		return 0, 0, false
	}
	online := len(registry.clients)
	queued := 0
	var slow []*client
	for receiver := range registry.clients {
		if receiver.enqueue(frame) {
			queued++
		} else {
			delete(registry.clients, receiver)
			slow = append(slow, receiver)
		}
	}
	registry.mutex.Unlock()
	for _, receiver := range slow {
		receiver.close()
	}
	if len(slow) > 0 {
		registry.logger.Warn("disconnected slow clients", "count", len(slow))
	}
	return online, queued, true
}

func (registry *hub) isClosed() bool {
	registry.mutex.Lock()
	defer registry.mutex.Unlock()
	return registry.closed
}

func (registry *hub) closeAll() {
	registry.mutex.Lock()
	registry.closed = true
	receivers := make([]*client, 0, len(registry.clients))
	for receiver := range registry.clients {
		receivers = append(receivers, receiver)
	}
	registry.mutex.Unlock()
	for _, receiver := range receivers {
		receiver.close()
	}
}

func newClient(connection *websocket.Conn, registry *hub, slots, byteLimit int) *client {
	return &client{
		connection: connection, hub: registry, frames: make([][]byte, slots),
		byteLimit: byteLimit, notify: make(chan struct{}, 1), stopped: make(chan struct{}),
	}
}

func (receiver *client) enqueue(frame []byte) bool {
	receiver.mutex.Lock()
	defer receiver.mutex.Unlock()
	if receiver.closed || receiver.count == len(receiver.frames) || len(frame) > receiver.byteLimit-receiver.bytes {
		return false
	}
	position := (receiver.head + receiver.count) % len(receiver.frames)
	receiver.frames[position] = frame
	receiver.count++
	receiver.bytes += len(frame)
	select {
	case receiver.notify <- struct{}{}:
	default:
	}
	return true
}

func (receiver *client) dequeue() ([]byte, bool) {
	receiver.mutex.Lock()
	defer receiver.mutex.Unlock()
	if receiver.closed || receiver.count == 0 {
		return nil, false
	}
	frame := receiver.frames[receiver.head]
	receiver.frames[receiver.head] = nil
	receiver.head = (receiver.head + 1) % len(receiver.frames)
	receiver.count--
	receiver.bytes -= len(frame)
	return frame, true
}

func (receiver *client) close() {
	receiver.closeOnce.Do(func() {
		receiver.mutex.Lock()
		receiver.closed = true
		clear(receiver.frames)
		receiver.count = 0
		receiver.bytes = 0
		receiver.mutex.Unlock()
		close(receiver.stopped)
		if receiver.connection != nil {
			receiver.connection.Close()
		}
		if receiver.hub != nil {
			receiver.hub.remove(receiver)
		}
	})
}

func (receiver *client) read() {
	defer receiver.hub.workers.Done()
	defer receiver.close()
	for {
		if _, _, err := receiver.connection.ReadMessage(); err != nil {
			return
		}
		receiver.connection.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.ClosePolicyViolation, "receiver connections accept control frames only"), time.Now().Add(time.Second))
		return
	}
}

func (receiver *client) write() {
	defer receiver.hub.workers.Done()
	defer receiver.close()
	for {
		select {
		case <-receiver.stopped:
			return
		case <-receiver.notify:
			for {
				frame, exists := receiver.dequeue()
				if !exists {
					break
				}
				if receiver.connection.SetWriteDeadline(time.Now().Add(writeTimeout)) != nil {
					return
				}
				if receiver.connection.WriteMessage(websocket.TextMessage, frame) != nil {
					return
				}
			}
		}
	}
}
