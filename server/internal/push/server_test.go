package push

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"tug/server/internal/config"
	"tug/server/internal/message"
)

const sendToken = "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
const receiveToken = "rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"

func testSettings() config.Config {
	settings := config.Defaults()
	settings.SendToken, settings.ReceiveToken = sendToken, receiveToken
	return settings
}

func testServer(t *testing.T, settings config.Config) (*Server, *httptest.Server) {
	t.Helper()
	service, err := New(settings, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	host := httptest.NewServer(service.Handler())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := service.Close(ctx); err != nil {
			t.Error(err)
		}
		host.Close()
	})
	return service, host
}

func post(t *testing.T, host *httptest.Server, token, body string) *http.Response {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, host.URL+"/api/v1/messages", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := host.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { response.Body.Close() })
	return response
}

func connect(t *testing.T, host *httptest.Server) *websocket.Conn {
	t.Helper()
	headers := http.Header{"Authorization": []string{"Bearer " + receiveToken}}
	connection, response, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(host.URL, "http")+"/api/v1/ws", headers)
	if response != nil {
		response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { connection.Close() })
	connection.SetReadDeadline(time.Now().Add(5 * time.Second))
	var hello struct {
		Type                     string `json:"type"`
		Version                  int    `json:"version"`
		HeartbeatIntervalSeconds int    `json:"heartbeat_interval_seconds"`
	}
	if err := connection.ReadJSON(&hello); err != nil || hello.Type != "hello" || hello.Version != 1 || hello.HeartbeatIntervalSeconds == 0 {
		t.Fatalf("invalid hello: %+v, %v", hello, err)
	}
	return connection
}

func waitClientCount(t *testing.T, service *Server, expected int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		service.hub.mutex.Lock()
		actual := len(service.hub.clients)
		service.hub.mutex.Unlock()
		if actual == expected {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("client count did not become %d", expected)
}

func TestHealthAuthenticationAndZeroClients(t *testing.T) {
	_, host := testServer(t, testSettings())
	response, err := host.Client().Get(host.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	contents, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK || strings.TrimSpace(string(contents)) != `{"status":"ok"}` {
		t.Fatalf("health: %d %s", response.StatusCode, contents)
	}
	for _, token := range []string{"", "invalid", receiveToken} {
		response := post(t, host, token, `{"title":"Alert","body":"Download complete"}`)
		if response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("invalid send credential accepted: %d", response.StatusCode)
		}
		response.Body.Close()
	}
	response = post(t, host, sendToken, `{"title":"Alert","body":"Download complete"}`)
	var accepted acceptedResponse
	if err := json.NewDecoder(response.Body).Decode(&accepted); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusAccepted || !accepted.Accepted || len(accepted.ID) != 36 || accepted.OnlineClients != 0 || accepted.QueuedClients != 0 || accepted.ReceivedAt.IsZero() {
		t.Fatalf("zero clients semantics incorrect: %+v (%d)", accepted, response.StatusCode)
	}
}

func TestRequestValidationAndLimit(t *testing.T) {
	settings := testSettings()
	settings.SendRateLimit = 1000
	_, host := testServer(t, settings)
	for _, testCase := range []struct {
		body        string
		contentType string
		status      int
	}{
		{`{"title":"Alert","body":"Done"}`, "text/plain", 415},
		{`{"title":"Alert","body":"Done"}`, "", 415},
		{`{"title":"Alert","body":"Done"}`, "application/json; charset=utf-8", 202},
		{`{"title":"Alert","body":"Done","unexpected":1}`, "application/json", 400},
		{`{"title":"Alert","body":"Done","timestamp":null}`, "application/json", 400},
		{`{"title":"Alert","body":"Done","timestamp":"invalid"}`, "application/json", 400},
		{`{"title":"Alert","body":"Done"} {}`, "application/json", 400},
		{strings.Repeat(" ", message.MaxRequestBytes+1), "application/json", 413},
	} {
		request, _ := http.NewRequest(http.MethodPost, host.URL+"/api/v1/messages", strings.NewReader(testCase.body))
		request.Header.Set("Authorization", "Bearer "+sendToken)
		request.Header.Set("Content-Type", testCase.contentType)
		response, err := host.Client().Do(request)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != testCase.status {
			t.Fatalf("expected %d, got %d", testCase.status, response.StatusCode)
		}
	}
	request, _ := http.NewRequest(http.MethodPost, host.URL+"/api/v1/messages", strings.NewReader(`{"title":"Alert","body":"Done"}`))
	request.Header["Authorization"] = []string{"Bearer " + sendToken, "Bearer " + sendToken}
	request.Header.Set("Content-Type", "application/json")
	response, err := host.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatal("duplicate authorization headers accepted")
	}
}

func TestBroadcastAndDisconnectCleanup(t *testing.T) {
	service, host := testServer(t, testSettings())
	first, second := connect(t, host), connect(t, host)
	waitClientCount(t, service, 2)
	response := post(t, host, sendToken, `{"title":"Alert","body":"Download complete\nFile saved","timestamp":"2026-10-10T20:00:00+08:00"}`)
	var accepted acceptedResponse
	if err := json.NewDecoder(response.Body).Decode(&accepted); err != nil {
		t.Fatal(err)
	}
	if accepted.OnlineClients != 2 || accepted.QueuedClients != 2 {
		t.Fatalf("incorrect broadcast counts: %+v", accepted)
	}
	for _, connection := range []*websocket.Conn{first, second} {
		var frame struct {
			Type    string          `json:"type"`
			Version int             `json:"version"`
			Message message.Message `json:"message"`
		}
		if err := connection.ReadJSON(&frame); err != nil {
			t.Fatal(err)
		}
		if frame.Type != "message" || frame.Version != 1 || frame.Message.ID != accepted.ID || frame.Message.Body != "Download complete\nFile saved" || frame.Message.Timestamp.Format(time.RFC3339) != "2026-10-10T12:00:00Z" {
			t.Fatalf("wrong broadcast frame: %+v", frame)
		}
	}
	first.Close()
	second.Close()
	waitClientCount(t, service, 0)
}

func TestWebSocketAuthenticationAndConnectionLimit(t *testing.T) {
	settings := testSettings()
	settings.MaxClients = 1
	service, host := testServer(t, settings)
	url := "ws" + strings.TrimPrefix(host.URL, "http") + "/api/v1/ws"
	for _, token := range []string{"", sendToken} {
		connection, response, err := websocket.DefaultDialer.Dial(url, http.Header{"Authorization": []string{"Bearer " + token}})
		if connection != nil {
			connection.Close()
		}
		if err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("invalid receive credential accepted: %v", err)
		}
		response.Body.Close()
	}
	first := connect(t, host)
	waitClientCount(t, service, 1)
	_, response, err := websocket.DefaultDialer.Dial(url, http.Header{"Authorization": []string{"Bearer " + receiveToken}})
	if err == nil || response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatal("connection limit was not enforced")
	}
	response.Body.Close()
	_, response, err = websocket.DefaultDialer.Dial(url+"?token=secret", http.Header{"Authorization": []string{"Bearer " + receiveToken}})
	if err == nil || response == nil || response.StatusCode != http.StatusBadRequest {
		t.Fatal("query parameters accepted")
	}
	response.Body.Close()
	first.Close()
	waitClientCount(t, service, 0)
	connect(t, host)
}

func TestPingPongAndIdleExpiry(t *testing.T) {
	settings := testSettings()
	settings.HeartbeatInterval = time.Second
	service, host := testServer(t, settings)
	connection := connect(t, host)
	waitClientCount(t, service, 1)
	pongReceived := false
	connection.SetPongHandler(func(payload string) error {
		if payload == "heartbeat" {
			pongReceived = true
			return connection.SetReadDeadline(time.Now())
		}
		return nil
	})
	if err := connection.WriteControl(websocket.PingMessage, []byte("heartbeat"), time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := connection.ReadMessage(); err == nil {
		t.Fatal("read should stop after pong")
	}
	if !pongReceived {
		t.Fatal("server did not reply with matching pong")
	}
	waitClientCount(t, service, 0)
}

func TestShutdownRejectsNewRequestsAndClosesConnections(t *testing.T) {
	service, host := testServer(t, testSettings())
	connection := connect(t, host)
	waitClientCount(t, service, 1)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := service.Close(ctx); err != nil {
		t.Fatal(err)
	}
	if _, _, err := connection.ReadMessage(); err == nil {
		t.Fatal("shutdown kept WebSocket open")
	}
	response := post(t, host, sendToken, `{"title":"Alert","body":"Done"}`)
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Fatal("shutting down server accepts messages")
	}
}

func TestHeartbeatKeepsClientAlive(t *testing.T) {
	settings := testSettings()
	settings.HeartbeatInterval = time.Second
	service, host := testServer(t, settings)
	connection := connect(t, host)
	waitClientCount(t, service, 1)
	readResult := make(chan error, 1)
	go func() {
		_, _, err := connection.ReadMessage()
		readResult <- err
	}()
	for attempt := 0; attempt < 4; attempt++ {
		time.Sleep(800 * time.Millisecond)
		if err := connection.WriteControl(websocket.PingMessage, []byte("keepalive"), time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	waitClientCount(t, service, 1)
	select {
	case err := <-readResult:
		t.Fatalf("heartbeating connection closed early: %v", err)
	default:
	}
	connection.Close()
	select {
	case <-readResult:
	case <-time.After(time.Second):
		t.Fatal("reader did not stop after client close")
	}
	waitClientCount(t, service, 0)
}

func TestConcurrentBroadcast(t *testing.T) {
	settings := testSettings()
	settings.SendRateLimit, settings.ClientQueueSize, settings.ClientQueueBytes = 1000, 128, 256*1024
	service, host := testServer(t, settings)
	first, second := connect(t, host), connect(t, host)
	waitClientCount(t, service, 2)
	const count = 50
	var senders sync.WaitGroup
	errors := make(chan error, count)
	for index := 0; index < count; index++ {
		senders.Add(1)
		go func(index int) {
			defer senders.Done()
			request, _ := http.NewRequest(http.MethodPost, host.URL+"/api/v1/messages", strings.NewReader(fmt.Sprintf(`{"title":"message %d","body":"test"}`, index)))
			request.Header.Set("Authorization", "Bearer "+sendToken)
			request.Header.Set("Content-Type", "application/json")
			response, err := host.Client().Do(request)
			if err != nil {
				errors <- err
				return
			}
			defer response.Body.Close()
			var accepted acceptedResponse
			if err := json.NewDecoder(response.Body).Decode(&accepted); err != nil {
				errors <- err
			} else if response.StatusCode != 202 || accepted.QueuedClients != 2 {
				errors <- fmt.Errorf("unexpected broadcast response: %d %+v", response.StatusCode, accepted)
			}
		}(index)
	}
	senders.Wait()
	close(errors)
	for err := range errors {
		t.Error(err)
	}
	for _, connection := range []*websocket.Conn{first, second} {
		seen := make(map[string]bool)
		for index := 0; index < count; index++ {
			var frame struct {
				Message message.Message `json:"message"`
			}
			if err := connection.ReadJSON(&frame); err != nil {
				t.Fatal(err)
			}
			seen[frame.Message.ID] = true
		}
		if len(seen) != count {
			t.Fatalf("messages lost/duplicated: %d", len(seen))
		}
	}
}

func TestRateLimitHTTP(t *testing.T) {
	settings := testSettings()
	settings.SendRateLimit = 1
	_, host := testServer(t, settings)
	for index, expected := range []int{202, 202, 429} {
		response := post(t, host, sendToken, `{"title":"Alert","body":"Done"}`)
		if response.StatusCode != expected {
			t.Fatalf("request %d: expected %d, got %d", index, expected, response.StatusCode)
		}
		response.Body.Close()
	}
}

func TestMissingUpgradeAndForeignOrigin(t *testing.T) {
	_, host := testServer(t, testSettings())
	request, _ := http.NewRequest(http.MethodGet, host.URL+"/api/v1/ws", nil)
	request.Header.Set("Authorization", "Bearer "+receiveToken)
	response, err := host.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 400 {
		t.Fatalf("missing upgrade expected 400, got %d", response.StatusCode)
	}
	headers := http.Header{"Authorization": []string{"Bearer " + receiveToken}, "Origin": []string{"https://untrusted.example"}}
	connection, response, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(host.URL, "http")+"/api/v1/ws", headers)
	if connection != nil {
		connection.Close()
	}
	if err == nil || response == nil || response.StatusCode != 403 {
		t.Fatal("foreign origin accepted")
	}
	response.Body.Close()
}

func TestReceiverRejectsDataAndOversizedFrames(t *testing.T) {
	for _, contents := range []string{`{"type":"message"}`, strings.Repeat("x", 2048)} {
		service, host := testServer(t, testSettings())
		connection := connect(t, host)
		if err := connection.WriteMessage(websocket.TextMessage, []byte(contents)); err != nil {
			t.Fatal(err)
		}
		if _, _, err := connection.ReadMessage(); err == nil {
			t.Fatal("unexpected client application frame accepted")
		}
		waitClientCount(t, service, 0)
	}
}

func TestLoadTwentyClients(t *testing.T) {
	settings := testSettings()
	settings.SendRateLimit = 1000
	service, host := testServer(t, settings)
	const clients = 20
	const messages = 100
	var readers sync.WaitGroup
	failures := make(chan error, clients)
	for index := 0; index < clients; index++ {
		connection := connect(t, host)
		readers.Add(1)
		go func() {
			defer readers.Done()
			seen := make(map[string]bool)
			for received := 0; received < messages; received++ {
				var frame struct {
					Message message.Message `json:"message"`
				}
				if err := connection.ReadJSON(&frame); err != nil {
					failures <- err
					return
				}
				seen[frame.Message.ID] = true
			}
			if len(seen) != messages {
				failures <- fmt.Errorf("received %d unique messages, expected %d", len(seen), messages)
			}
		}()
	}
	waitClientCount(t, service, clients)
	started := time.Now()
	for index := 0; index < messages; index++ {
		response := post(t, host, sendToken, `{"title":"load","body":"short message"}`)
		var accepted acceptedResponse
		err := json.NewDecoder(response.Body).Decode(&accepted)
		response.Body.Close()
		if err != nil || response.StatusCode != 202 || accepted.QueuedClients != clients {
			t.Fatalf("load send %d: %d %+v %v", index, response.StatusCode, accepted, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	readers.Wait()
	close(failures)
	for err := range failures {
		t.Error(err)
	}
	t.Logf("%d clients received %d broadcasts (%d deliveries) in %s; short local functional load, not constrained-vCPU or long-term acceptance", clients, messages, clients*messages, time.Since(started))
}
