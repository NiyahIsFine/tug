package push

import (
	"net"
	"testing"
	"time"
)

func TestBoundedListenerReleasesSlotAndCloses(t *testing.T) {
	underlying, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listener := &boundedListener{Listener: underlying, slots: make(chan struct{}, 1), closed: make(chan struct{})}
	defer listener.Close()
	peer, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	accepted, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer accepted.Close()
	if len(listener.slots) != 1 {
		t.Fatal("accepted TCP connection did not reserve capacity")
	}
	accepted.Close()
	accepted.Close()
	if len(listener.slots) != 0 {
		t.Fatal("close did not release capacity exactly once")
	}
	listener.slots <- struct{}{}
	finished := make(chan error, 1)
	go func() {
		_, err := listener.Accept()
		finished <- err
	}()
	listener.Close()
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("closed listener accepted connection")
		}
	case <-time.After(time.Second):
		t.Fatal("close did not unblock capacity wait")
	}
}
