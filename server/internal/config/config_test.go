package config

import (
	"errors"
	"flag"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func environment(values map[string]string) func(string) (string, bool) {
	return func(name string) (string, bool) {
		value, found := values[name]
		return value, found
	}
}

func TestDefaultListenAddress(t *testing.T) {
	if settings := Defaults(); settings.ListenAddr != ":16640" {
		t.Fatalf("unexpected default listen address: %s", settings.ListenAddr)
	}
	settings, err := Load(nil, environment(map[string]string{
		"TUG_SEND_TOKEN": "test-send-token", "TUG_RECEIVE_TOKEN": "test-receive-token",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if settings.ListenAddr != ":16640" {
		t.Fatalf("unexpected loaded listen address: %s", settings.ListenAddr)
	}
}

func TestLoadPrecedence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "server.yaml")
	contents := "listen_addr: '127.0.0.1:9000'\nlog_level: info\nmax_clients: 7\nheartbeat_interval: 60s\n"
	if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
	settings, err := Load([]string{"--config", path, "--listen", "127.0.0.1:9002", "--max-clients", "9"}, environment(map[string]string{
		"TUG_SEND_TOKEN": strings.Repeat("s", 64), "TUG_RECEIVE_TOKEN": strings.Repeat("r", 64),
		"TUG_LISTEN_ADDR": "127.0.0.1:9001", "TUG_MAX_CLIENTS": "8", "TUG_HEARTBEAT_INTERVAL": "90s",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if settings.ListenAddr != "127.0.0.1:9002" || settings.MaxClients != 9 || settings.LogLevel != "info" || settings.HeartbeatInterval != 90*time.Second || settings.ClientQueueBytes != 65536 {
		t.Fatalf("incorrect precedence or defaults: %+v", settings)
	}
}

func TestRejectInvalidConfigurations(t *testing.T) {
	for _, testCase := range []struct {
		name   string
		change func(*Config)
	}{
		{"missing token", func(settings *Config) { settings.SendToken = "" }},
		{"single byte token", func(settings *Config) { settings.ReceiveToken = "r" }},
		{"same tokens", func(settings *Config) { settings.ReceiveToken = settings.SendToken }},
		{"token whitespace", func(settings *Config) { settings.SendToken += " " }},
		{"non ASCII token", func(settings *Config) { settings.SendToken = "😀" }},
		{"control character token", func(settings *Config) { settings.SendToken = "ab\ncd" }},
		{"bad listen", func(settings *Config) { settings.ListenAddr = "localhost" }},
		{"bad port", func(settings *Config) { settings.ListenAddr = ":99999" }},
		{"bad log level", func(settings *Config) { settings.LogLevel = "verbose" }},
		{"short heartbeat", func(settings *Config) { settings.HeartbeatInterval = time.Millisecond }},
		{"fractional heartbeat", func(settings *Config) { settings.HeartbeatInterval = 1500 * time.Millisecond }},
		{"long heartbeat", func(settings *Config) { settings.HeartbeatInterval = time.Hour }},
		{"zero connections", func(settings *Config) { settings.MaxClients = 0 }},
		{"queue too small", func(settings *Config) { settings.ClientQueueSize = 0 }},
		{"queue too large", func(settings *Config) { settings.ClientQueueBytes = 5000000 }},
		{"rate zero", func(settings *Config) { settings.SendRateLimit = 0 }},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			settings := Defaults()
			settings.SendToken, settings.ReceiveToken = strings.Repeat("s", 64), strings.Repeat("r", 64)
			testCase.change(&settings)
			if settings.Validate() == nil {
				t.Fatal("invalid configuration was accepted")
			}
		})
	}
}

func TestInvalidFileAndEnvironmentDoNotLeakSecrets(t *testing.T) {
	secret := strings.Repeat("SECRET", 10)
	values := map[string]string{"TUG_SEND_TOKEN": secret, "TUG_RECEIVE_TOKEN": strings.Repeat("r", 64)}
	for _, contents := range []string{
		"send_token: [" + secret + "\n",
		"unknown: " + secret + "\n",
		"max_clients: " + secret + "\n",
		"send_token: one\nsend_token: two\n",
		"listen_addr: ':16640'\n---\nlisten_addr: ':9000'\n",
	} {
		path := filepath.Join(t.TempDir(), "server.yaml")
		if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
		_, err := Load([]string{"--config", path}, environment(values))
		if err == nil || strings.Contains(err.Error(), secret) {
			t.Fatalf("invalid or leaking configuration error: %v", err)
		}
	}
	values["TUG_MAX_CLIENTS"] = secret
	if _, err := Load(nil, environment(values)); err == nil || strings.Contains(err.Error(), secret) {
		t.Fatalf("invalid or leaking environment error: %v", err)
	}
	if _, err := Load([]string{"--max-clients", secret}, environment(values)); err == nil || strings.Contains(err.Error(), secret) {
		t.Fatalf("invalid or leaking argument error: %v", err)
	}
}

func TestHelpAndPositionalArguments(t *testing.T) {
	if _, err := Load([]string{"--help"}, environment(nil)); !errors.Is(err, flag.ErrHelp) {
		t.Fatalf("expected help: %v", err)
	}
	if _, err := Load([]string{"unexpected"}, environment(nil)); err == nil {
		t.Fatal("positional arguments accepted")
	}
}

func TestMessageLoggingDefaultsAndPrecedence(t *testing.T) {
	values := map[string]string{"TUG_SEND_TOKEN": strings.Repeat("s", 64), "TUG_RECEIVE_TOKEN": strings.Repeat("r", 64)}
	settings, err := Load(nil, environment(values))
	if err != nil || !settings.LogMessages || settings.LogLevel != "info" {
		t.Fatalf("message logging defaults: %+v %v", settings, err)
	}
	path := filepath.Join(t.TempDir(), "server.yaml")
	if err := os.WriteFile(path, []byte("log_messages: false\n"), 0600); err != nil {
		t.Fatal(err)
	}
	settings, err = Load([]string{"--config", path}, environment(values))
	if err != nil || settings.LogMessages {
		t.Fatalf("YAML disabled logging: %+v %v", settings, err)
	}
	values["TUG_LOG_MESSAGES"] = "true"
	settings, err = Load([]string{"--config", path}, environment(values))
	if err != nil || !settings.LogMessages {
		t.Fatalf("environment override: %+v %v", settings, err)
	}
	settings, err = Load([]string{"--config", path, "--log-messages=false"}, environment(values))
	if err != nil || settings.LogMessages {
		t.Fatalf("CLI override: %+v %v", settings, err)
	}
	values["TUG_LOG_MESSAGES"] = "SECRET-invalid-value"
	_, err = Load(nil, environment(values))
	if err == nil || strings.Contains(err.Error(), values["TUG_LOG_MESSAGES"]) {
		t.Fatalf("invalid logging boolean error: %v", err)
	}
}

func TestCustomTokenCLIOverridesEnvironment(t *testing.T) {
	settings, err := Load([]string{
		"--send-token", "my-own-send-token-2026-abcdefghijk",
		"--receive-token", "my-own-receive-token-2026-abcdefghijk",
	}, environment(map[string]string{
		"TUG_SEND_TOKEN": strings.Repeat("s", 64), "TUG_RECEIVE_TOKEN": strings.Repeat("r", 64),
	}))
	if err != nil || settings.SendToken != "my-own-send-token-2026-abcdefghijk" || settings.ReceiveToken != "my-own-receive-token-2026-abcdefghijk" {
		t.Fatalf("custom CLI token override: %v", err)
	}
}

func TestTokenLengthAcrossConfigurationSources(t *testing.T) {
	for _, length := range []int{0, 1, 2, 31, 32, 512, 513, 2048} {
		for _, source := range []string{"environment", "cli", "yaml"} {
			t.Run(source+"/"+strconv.Itoa(length), func(t *testing.T) {
				send := strings.Repeat("s", length)
				receive := strings.Repeat("r", length)
				var arguments []string
				values := map[string]string{}
				switch source {
				case "environment":
					values["TUG_SEND_TOKEN"], values["TUG_RECEIVE_TOKEN"] = send, receive
				case "cli":
					arguments = []string{"--send-token", send, "--receive-token", receive}
				case "yaml":
					path := filepath.Join(t.TempDir(), "server.yaml")
					contents := "send_token: '" + send + "'\nreceive_token: '" + receive + "'\n"
					if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
						t.Fatal(err)
					}
					arguments = []string{"--config", path}
				}
				settings, err := Load(arguments, environment(values))
				if length < 2 {
					if err == nil {
						t.Fatal("empty or single byte token accepted")
					}
					return
				}
				if err != nil || settings.SendToken != send || settings.ReceiveToken != receive {
					t.Fatalf("token length %d from %s rejected: %v", length, source, err)
				}
			})
		}
	}
}
