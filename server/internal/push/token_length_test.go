package push

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestShortAndLongTokensAuthenticateHTTPAndWebSocket(t *testing.T) {
	for _, length := range []int{2, 513, 2048} {
		settings := testSettings()
		settings.SendToken = strings.Repeat("s", length)
		settings.ReceiveToken = strings.Repeat("r", length)
		service, host := testServer(t, settings)
		url := "ws" + strings.TrimPrefix(host.URL, "http") + "/api/v1/ws"
		for _, wrong := range []string{"", "r", settings.SendToken} {
			connection, response, err := websocket.DefaultDialer.Dial(url, http.Header{"Authorization": []string{"Bearer " + wrong}})
			if connection != nil {
				connection.Close()
			}
			if err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
				t.Fatalf("wrong receive token accepted at length %d", length)
			}
			response.Body.Close()
		}
		connection, response, err := websocket.DefaultDialer.Dial(url, http.Header{"Authorization": []string{"Bearer " + settings.ReceiveToken}})
		if response != nil {
			response.Body.Close()
		}
		if err != nil {
			t.Fatalf("WebSocket token length %d rejected: %v", length, err)
		}
		t.Cleanup(func() { connection.Close() })
		connection.SetReadDeadline(time.Now().Add(5 * time.Second))
		var hello map[string]any
		if err := connection.ReadJSON(&hello); err != nil || hello["type"] != "hello" {
			t.Fatalf("invalid hello: %v", err)
		}
		waitClientCount(t, service, 1)
		for _, wrong := range []string{"", "s", settings.ReceiveToken, settings.SendToken + "!"} {
			response := post(t, host, wrong, `{"title":"test","body":"token test"}`)
			response.Body.Close()
			if response.StatusCode != http.StatusUnauthorized {
				t.Fatalf("wrong send token accepted at length %d", length)
			}
		}
		response = post(t, host, settings.SendToken, `{"title":"test","body":"token test"}`)
		var accepted acceptedResponse
		err = json.NewDecoder(response.Body).Decode(&accepted)
		response.Body.Close()
		if err != nil || response.StatusCode != http.StatusAccepted || accepted.QueuedClients != 1 {
			t.Fatalf("HTTP token length %d rejected: %v (%d)", length, err, response.StatusCode)
		}
		var frame struct {
			Message struct {
				ID string `json:"id"`
			} `json:"message"`
		}
		if err := connection.ReadJSON(&frame); err != nil || frame.Message.ID != accepted.ID {
			t.Fatalf("broadcast with token length %d failed: %v", length, err)
		}
		connection.Close()
		waitClientCount(t, service, 0)
	}
}
