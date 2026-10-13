package push

import (
	"net"
	"sync"
)

type boundedListener struct {
	net.Listener
	slots     chan struct{}
	closed    chan struct{}
	closeOnce sync.Once
}

type boundedConnection struct {
	net.Conn
	slots     chan struct{}
	closeOnce sync.Once
}

func (server *Server) Listen() (net.Listener, error) {
	listener, err := net.Listen("tcp", server.settings.ListenAddr)
	if err != nil {
		return nil, err
	}
	return &boundedListener{
		Listener: listener, slots: make(chan struct{}, server.settings.MaxClients+32), closed: make(chan struct{}),
	}, nil
}

func (listener *boundedListener) Accept() (net.Conn, error) {
	select {
	case listener.slots <- struct{}{}:
	case <-listener.closed:
		return nil, net.ErrClosed
	}
	connection, err := listener.Listener.Accept()
	if err != nil {
		<-listener.slots
		return nil, err
	}
	return &boundedConnection{Conn: connection, slots: listener.slots}, nil
}

func (listener *boundedListener) Close() error {
	var closeError error
	listener.closeOnce.Do(func() {
		close(listener.closed)
		closeError = listener.Listener.Close()
	})
	return closeError
}

func (connection *boundedConnection) Close() error {
	var closeError error
	connection.closeOnce.Do(func() {
		closeError = connection.Conn.Close()
		<-connection.slots
	})
	return closeError
}
