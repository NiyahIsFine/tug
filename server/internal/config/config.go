package config

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

type Config struct {
	ListenAddr        string
	SendToken         string
	ReceiveToken      string
	LogLevel          string
	LogMessages       bool
	HeartbeatInterval time.Duration
	MaxClients        int
	ClientQueueSize   int
	ClientQueueBytes  int
	SendRateLimit     int
}

type fileConfig struct {
	ListenAddr        *string `yaml:"listen_addr"`
	SendToken         *string `yaml:"send_token"`
	ReceiveToken      *string `yaml:"receive_token"`
	LogLevel          *string `yaml:"log_level"`
	LogMessages       *bool   `yaml:"log_messages"`
	HeartbeatInterval *string `yaml:"heartbeat_interval"`
	MaxClients        *int    `yaml:"max_clients"`
	ClientQueueSize   *int    `yaml:"client_queue_size"`
	ClientQueueBytes  *int    `yaml:"client_queue_bytes"`
	SendRateLimit     *int    `yaml:"send_rate_limit"`
}

func Defaults() Config {
	return Config{
		ListenAddr: ":16640", LogLevel: "info", LogMessages: true, HeartbeatInterval: 120 * time.Second,
		MaxClients: 32, ClientQueueSize: 16, ClientQueueBytes: 65536, SendRateLimit: 10,
	}
}

func Load(arguments []string, lookup func(string) (string, bool)) (Config, error) {
	settings := Defaults()
	flags := flag.NewFlagSet("tug-server", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	configPath := flags.String("config", "", "YAML configuration file")
	flags.StringVar(&settings.ListenAddr, "listen", settings.ListenAddr, "HTTP listen address")
	flags.StringVar(&settings.SendToken, "send-token", "", "send token (prefer environment)")
	flags.StringVar(&settings.ReceiveToken, "receive-token", "", "receive token (prefer environment)")
	flags.StringVar(&settings.LogLevel, "log-level", settings.LogLevel, "debug, info, warn, error")
	flags.BoolVar(&settings.LogMessages, "log-messages", settings.LogMessages, "log accepted message data (disable for sensitive content)")
	flags.DurationVar(&settings.HeartbeatInterval, "heartbeat-interval", settings.HeartbeatInterval, "client ping interval")
	flags.IntVar(&settings.MaxClients, "max-clients", settings.MaxClients, "maximum connections")
	flags.IntVar(&settings.ClientQueueSize, "client-queue-size", settings.ClientQueueSize, "queued frames per client")
	flags.IntVar(&settings.ClientQueueBytes, "client-queue-bytes", settings.ClientQueueBytes, "queued bytes per client")
	flags.IntVar(&settings.SendRateLimit, "send-rate-limit", settings.SendRateLimit, "messages per second, burst is twice this")
	if err := flags.Parse(arguments); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return Config{}, flag.ErrHelp
		}
		return Config{}, errors.New("invalid command arguments; use --help (values omitted for safety)")
	}
	if flags.NArg() != 0 {
		return Config{}, errors.New("unexpected positional arguments")
	}
	overrides := settings
	settings = Defaults()
	if *configPath != "" {
		if err := settings.readFile(*configPath); err != nil {
			return Config{}, err
		}
	}
	if err := settings.applyEnvironment(lookup); err != nil {
		return Config{}, err
	}
	flags.Visit(func(option *flag.Flag) {
		switch option.Name {
		case "listen":
			settings.ListenAddr = overrides.ListenAddr
		case "send-token":
			settings.SendToken = overrides.SendToken
		case "receive-token":
			settings.ReceiveToken = overrides.ReceiveToken
		case "log-level":
			settings.LogLevel = overrides.LogLevel
		case "log-messages":
			settings.LogMessages = overrides.LogMessages
		case "heartbeat-interval":
			settings.HeartbeatInterval = overrides.HeartbeatInterval
		case "max-clients":
			settings.MaxClients = overrides.MaxClients
		case "client-queue-size":
			settings.ClientQueueSize = overrides.ClientQueueSize
		case "client-queue-bytes":
			settings.ClientQueueBytes = overrides.ClientQueueBytes
		case "send-rate-limit":
			settings.SendRateLimit = overrides.SendRateLimit
		}
	})
	return settings, settings.Validate()
}

func (settings *Config) readFile(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return errors.New("cannot open configuration file")
	}
	defer file.Close()
	contents, err := io.ReadAll(io.LimitReader(file, 65537))
	if err != nil || len(contents) > 65536 {
		return errors.New("cannot read configuration file or file exceeds 64 KiB")
	}
	decoder := yaml.NewDecoder(bytes.NewReader(contents))
	decoder.KnownFields(true)
	var document fileConfig
	if err := decoder.Decode(&document); err != nil {
		return errors.New("invalid YAML configuration (details omitted to protect tokens)")
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("configuration must contain exactly one YAML document")
	}
	assignString(&settings.ListenAddr, document.ListenAddr)
	assignString(&settings.SendToken, document.SendToken)
	assignString(&settings.ReceiveToken, document.ReceiveToken)
	assignString(&settings.LogLevel, document.LogLevel)
	if document.LogMessages != nil {
		settings.LogMessages = *document.LogMessages
	}
	assignInt(&settings.MaxClients, document.MaxClients)
	assignInt(&settings.ClientQueueSize, document.ClientQueueSize)
	assignInt(&settings.ClientQueueBytes, document.ClientQueueBytes)
	assignInt(&settings.SendRateLimit, document.SendRateLimit)
	if document.HeartbeatInterval != nil {
		interval, err := time.ParseDuration(*document.HeartbeatInterval)
		if err != nil {
			return errors.New("invalid heartbeat_interval")
		}
		settings.HeartbeatInterval = interval
	}
	return nil
}

func assignString(target *string, value *string) {
	if value != nil {
		*target = *value
	}
}

func assignInt(target *int, value *int) {
	if value != nil {
		*target = *value
	}
}

func (settings *Config) applyEnvironment(lookup func(string) (string, bool)) error {
	if value, exists := lookup("TUG_LOG_MESSAGES"); exists {
		parsed, err := strconv.ParseBool(value)
		if err != nil {
			return errors.New("invalid TUG_LOG_MESSAGES (use true or false)")
		}
		settings.LogMessages = parsed
	}
	for name, target := range map[string]*string{
		"TUG_LISTEN_ADDR": &settings.ListenAddr, "TUG_SEND_TOKEN": &settings.SendToken,
		"TUG_RECEIVE_TOKEN": &settings.ReceiveToken, "TUG_LOG_LEVEL": &settings.LogLevel,
	} {
		if value, exists := lookup(name); exists {
			*target = value
		}
	}
	for name, target := range map[string]*int{
		"TUG_MAX_CLIENTS": &settings.MaxClients, "TUG_CLIENT_QUEUE_SIZE": &settings.ClientQueueSize,
		"TUG_CLIENT_QUEUE_BYTES": &settings.ClientQueueBytes, "TUG_SEND_RATE_LIMIT": &settings.SendRateLimit,
	} {
		if value, exists := lookup(name); exists {
			parsed, err := strconv.Atoi(value)
			if err != nil {
				return fmt.Errorf("invalid %s", name)
			}
			*target = parsed
		}
	}
	if value, exists := lookup("TUG_HEARTBEAT_INTERVAL"); exists {
		parsed, err := time.ParseDuration(value)
		if err != nil {
			return errors.New("invalid TUG_HEARTBEAT_INTERVAL")
		}
		settings.HeartbeatInterval = parsed
	}
	return nil
}

func (settings Config) Validate() error {
	_, port, err := net.SplitHostPort(settings.ListenAddr)
	if err != nil {
		return errors.New("listen address must be host:port")
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 0 || portNumber > 65535 {
		return errors.New("listen port must be between 0 and 65535")
	}
	for _, token := range []string{settings.SendToken, settings.ReceiveToken} {
		if !ValidToken(token) {
			return errors.New("both tokens must contain at least 2 printable ASCII bytes without spaces")
		}
	}
	if settings.SendToken == settings.ReceiveToken {
		return errors.New("send and receive tokens must differ")
	}
	switch settings.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		return errors.New("log level must be debug, info, warn or error")
	}
	if settings.HeartbeatInterval < time.Second || settings.HeartbeatInterval > 10*time.Minute || settings.HeartbeatInterval%time.Second != 0 {
		return errors.New("heartbeat interval must be whole seconds between 1s and 10m")
	}
	if settings.MaxClients < 1 || settings.MaxClients > 4096 {
		return errors.New("max clients must be between 1 and 4096")
	}
	if settings.ClientQueueSize < 1 || settings.ClientQueueSize > 1024 {
		return errors.New("client queue size must be between 1 and 1024")
	}
	if settings.ClientQueueBytes < 32768 || settings.ClientQueueBytes > 4*1024*1024 {
		return errors.New("client queue bytes must be between 32768 and 4194304")
	}
	if settings.SendRateLimit < 1 || settings.SendRateLimit > 10000 {
		return errors.New("send rate limit must be between 1 and 10000")
	}
	return nil
}

func ValidToken(token string) bool {
	return len(token) >= 2 && strings.IndexFunc(token, func(character rune) bool {
		return character < 33 || character > 126
	}) < 0
}
