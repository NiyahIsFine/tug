package push

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"tug/server/internal/config"
	"tug/server/internal/message"
)

type Server struct {
	settings      config.Config
	logger        *slog.Logger
	hub           *hub
	sendDigest    [32]byte
	receiveDigest [32]byte
	upgrader      websocket.Upgrader
	limiter       rateLimiter
	handler       http.Handler
}

type rateLimiter struct {
	mutex  sync.Mutex
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
}

type acceptedResponse struct {
	ID            string    `json:"id"`
	Accepted      bool      `json:"accepted"`
	OnlineClients int       `json:"online_clients"`
	QueuedClients int       `json:"queued_clients"`
	ReceivedAt    time.Time `json:"received_at"`
}

func New(settings config.Config, logger *slog.Logger) (*Server, error) {
	if err := settings.Validate(); err != nil {
		return nil, err
	}
	if logger == nil {
		logger = slog.Default()
	}
	server := &Server{
		settings: settings, logger: logger, hub: newHub(settings.MaxClients, logger),
		sendDigest: sha256.Sum256([]byte(settings.SendToken)), receiveDigest: sha256.Sum256([]byte(settings.ReceiveToken)),
		upgrader: websocket.Upgrader{
			HandshakeTimeout: writeTimeout, ReadBufferSize: 512, WriteBufferSize: 1024,
			WriteBufferPool: &sync.Pool{}, EnableCompression: false,
			Error: func(writer http.ResponseWriter, request *http.Request, status int, reason error) {
				writeError(writer, status, "invalid_websocket", "invalid WebSocket handshake")
			},
		},
		limiter: rateLimiter{rate: float64(settings.SendRateLimit), burst: float64(settings.SendRateLimit * 2), tokens: float64(settings.SendRateLimit * 2), last: time.Now()},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", server.health)
	mux.HandleFunc("POST /api/v1/messages", server.send)
	mux.HandleFunc("GET /api/v1/ws", server.connect)
	server.handler = http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Cache-Control", "no-store")
		writer.Header().Set("X-Content-Type-Options", "nosniff")
		mux.ServeHTTP(writer, request)
	})
	return server, nil
}

func (server *Server) Handler() http.Handler {
	return server.handler
}

func (server *Server) HTTPServer() *http.Server {
	return &http.Server{
		Addr: server.settings.ListenAddr, Handler: server.handler,
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: writeTimeout, WriteTimeout: writeTimeout,
		IdleTimeout: 60 * time.Second, MaxHeaderBytes: 8 * 1024,
	}
}

func (server *Server) Close(ctx context.Context) error {
	server.hub.closeAll()
	finished := make(chan struct{})
	go func() {
		server.hub.workers.Wait()
		close(finished)
	}()
	select {
	case <-finished:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (server *Server) health(writer http.ResponseWriter, request *http.Request) {
	if server.hub.isClosed() {
		writeError(writer, http.StatusServiceUnavailable, "shutting_down", "server is shutting down")
		return
	}
	writeJSON(writer, http.StatusOK, struct {
		Status string `json:"status"`
	}{Status: "ok"})
}

func authorized(request *http.Request, expected [32]byte) bool {
	values := request.Header.Values("Authorization")
	if len(values) != 1 {
		return false
	}
	token, found := strings.CutPrefix(values[0], "Bearer ")
	if !found || !config.ValidToken(token) {
		return false
	}
	digest := sha256.Sum256([]byte(token))
	return subtle.ConstantTimeCompare(digest[:], expected[:]) == 1
}

func authenticate(writer http.ResponseWriter, request *http.Request, expected [32]byte) bool {
	if authorized(request, expected) {
		return true
	}
	writer.Header().Set("WWW-Authenticate", `Bearer realm="tug"`)
	writeError(writer, http.StatusUnauthorized, "unauthorized", "authentication failed")
	return false
}

func (server *Server) send(writer http.ResponseWriter, request *http.Request) {
	if !authenticate(writer, request, server.sendDigest) {
		return
	}
	if server.hub.isClosed() {
		writeError(writer, http.StatusServiceUnavailable, "shutting_down", "server is shutting down")
		return
	}
	contentType, _, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || contentType != "application/json" {
		writeError(writer, http.StatusUnsupportedMediaType, "unsupported_content_type", "Content-Type must be application/json")
		return
	}
	if !server.limiter.allow(time.Now()) {
		writer.Header().Set("Retry-After", "1")
		writeError(writer, http.StatusTooManyRequests, "rate_limited", "message rate limit exceeded")
		return
	}
	request.Body = http.MaxBytesReader(writer, request.Body, message.MaxRequestBytes)
	contents, err := io.ReadAll(request.Body)
	if err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeError(writer, http.StatusRequestEntityTooLarge, "request_too_large", "request exceeds 32 KiB")
		} else {
			writeError(writer, http.StatusBadRequest, "invalid_request", "cannot read request body")
		}
		return
	}
	parsed, err := message.Parse(contents, time.Now())
	if err != nil {
		writeError(writer, http.StatusBadRequest, "invalid_message", err.Error())
		return
	}
	parsed.ID, err = message.NewID()
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "internal_error", "cannot create message ID")
		return
	}
	data, err := json.Marshal(parsed)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "internal_error", "cannot encode message")
		return
	}
	frame := make([]byte, 0, len(data)+40)
	frame = append(frame, `{"type":"message","version":1,"message":`...)
	frame = append(frame, data...)
	frame = append(frame, '}')
	online, queued, open := server.hub.broadcast(frame)
	if !open {
		writeError(writer, http.StatusServiceUnavailable, "shutting_down", "server is shutting down")
		return
	}
	if server.settings.LogMessages && server.logger.Enabled(request.Context(), slog.LevelInfo) {
		server.logger.InfoContext(request.Context(), "message accepted", "data", string(data), "online_clients", online, "queued_clients", queued)
	}
	writeJSON(writer, http.StatusAccepted, acceptedResponse{ID: parsed.ID, Accepted: true, OnlineClients: online, QueuedClients: queued, ReceivedAt: parsed.ReceivedAt})
}

func (server *Server) connect(writer http.ResponseWriter, request *http.Request) {
	if !authenticate(writer, request, server.receiveDigest) {
		return
	}
	if request.URL.RawQuery != "" {
		writeError(writer, http.StatusBadRequest, "invalid_request", "WebSocket query parameters are not supported")
		return
	}
	if !server.hub.reserve() {
		writeError(writer, http.StatusServiceUnavailable, "connection_unavailable", "server is shutting down or connection limit reached")
		return
	}
	defer server.hub.release()
	connection, err := server.upgrader.Upgrade(writer, request, nil)
	if err != nil {
		return
	}
	readWindow := server.settings.HeartbeatInterval * 5 / 2
	connection.SetReadLimit(1024)
	if connection.SetReadDeadline(time.Now().Add(readWindow)) != nil {
		connection.Close()
		return
	}
	connection.SetPingHandler(func(payload string) error {
		if err := connection.WriteControl(websocket.PongMessage, []byte(payload), time.Now().Add(time.Second)); err != nil {
			return err
		}
		return connection.SetReadDeadline(time.Now().Add(readWindow))
	})
	hello := struct {
		Type                     string    `json:"type"`
		Version                  int       `json:"version"`
		HeartbeatIntervalSeconds int       `json:"heartbeat_interval_seconds"`
		ServerTime               time.Time `json:"server_time"`
	}{Type: "hello", Version: 1, HeartbeatIntervalSeconds: int(server.settings.HeartbeatInterval / time.Second), ServerTime: time.Now().UTC()}
	frame, err := json.Marshal(hello)
	if err != nil {
		connection.Close()
		return
	}
	receiver := newClient(connection, server.hub, server.settings.ClientQueueSize, server.settings.ClientQueueBytes)
	if !receiver.enqueue(frame) {
		receiver.close()
		return
	}
	if !server.hub.attach(receiver) {
		receiver.close()
	}
}

func (limiter *rateLimiter) allow(now time.Time) bool {
	limiter.mutex.Lock()
	defer limiter.mutex.Unlock()
	limiter.tokens += now.Sub(limiter.last).Seconds() * limiter.rate
	if limiter.tokens > limiter.burst {
		limiter.tokens = limiter.burst
	}
	limiter.last = now
	if limiter.tokens < 1 {
		return false
	}
	limiter.tokens--
	return true
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.WriteHeader(status)
	json.NewEncoder(writer).Encode(value)
}

func writeError(writer http.ResponseWriter, status int, code, description string) {
	writeJSON(writer, status, struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}{Error: struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}{Code: code, Message: description}})
}
