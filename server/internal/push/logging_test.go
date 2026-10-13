package push

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMessageLogsContainDataAndCountsWithoutCredentials(t *testing.T) {
	var output bytes.Buffer
	service, err := New(testSettings(), slog.New(slog.NewJSONHandler(&output, nil)))
	if err != nil {
		t.Fatal(err)
	}
	host := httptest.NewServer(service.Handler())
	defer host.Close()
	defer service.Close(context.Background())
	response := post(t, host, sendToken, `{"title":"Test alert","body":"Download complete\nSecond line\u001b[31m","timestamp":"2026-10-10T12:00:00Z"}`)
	var accepted acceptedResponse
	if err := json.NewDecoder(response.Body).Decode(&accepted); err != nil {
		t.Fatal(err)
	}
	contents := output.String()
	if strings.Count(contents, "\n") != 1 || strings.Contains(contents, "\x1b") || strings.Contains(contents, sendToken) || strings.Contains(contents, receiveToken) || strings.Contains(contents, "Authorization") {
		t.Fatalf("unsafe message log: %q", contents)
	}
	var record struct {
		Message       string `json:"msg"`
		Data          string `json:"data"`
		OnlineClients int    `json:"online_clients"`
		QueuedClients int    `json:"queued_clients"`
	}
	if err := json.Unmarshal(output.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	var data map[string]any
	if err := json.Unmarshal([]byte(record.Data), &data); err != nil {
		t.Fatal(err)
	}
	if record.Message != "message accepted" || data["id"] != accepted.ID || data["title"] != "Test alert" || data["body"] != "Download complete\nSecond line\x1b[31m" || record.OnlineClients != 0 || record.QueuedClients != 0 {
		t.Fatalf("incorrect message log: %+v %+v", record, data)
	}
	if data["timestamp"] == nil || data["received_at"] == nil {
		t.Fatal("missing message time fields")
	}
}

func TestMessageLogsDisabledOrRejected(t *testing.T) {
	for _, testCase := range []struct {
		name    string
		enabled bool
		level   slog.Level
		token   string
		body    string
	}{
		{"disabled", false, slog.LevelInfo, sendToken, `{"title":"test","body":"secret"}`},
		{"level filtered", true, slog.LevelWarn, sendToken, `{"title":"test","body":"secret"}`},
		{"unauthorized", true, slog.LevelInfo, receiveToken, `{"title":"test","body":"secret"}`},
		{"invalid", true, slog.LevelInfo, sendToken, `{"title":"test"}`},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			var output bytes.Buffer
			settings := testSettings()
			settings.LogMessages = testCase.enabled
			service, err := New(settings, slog.New(slog.NewTextHandler(&output, &slog.HandlerOptions{Level: testCase.level})))
			if err != nil {
				t.Fatal(err)
			}
			host := httptest.NewServer(service.Handler())
			defer host.Close()
			defer service.Close(context.Background())
			response := post(t, host, testCase.token, testCase.body)
			io.Copy(io.Discard, response.Body)
			response.Body.Close()
			if output.Len() != 0 {
				t.Fatalf("unexpected log: %s", output.String())
			}
		})
	}
}

func TestTextLogsEscapeTerminalControlCharacters(t *testing.T) {
	var output bytes.Buffer
	service, err := New(testSettings(), slog.New(slog.NewTextHandler(&output, nil)))
	if err != nil {
		t.Fatal(err)
	}
	host := httptest.NewServer(service.Handler())
	defer host.Close()
	defer service.Close(context.Background())
	response := post(t, host, sendToken, `{"title":"test","body":"line1\nline2\u001b[31m"}`)
	io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if strings.Count(output.String(), "\n") != 1 || strings.Contains(output.String(), "\x1b") || !strings.Contains(output.String(), "data=") {
		t.Fatalf("unsafe or missing text log: %q", output.String())
	}
}
