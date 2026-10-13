package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"tug/server/internal/config"
	"tug/server/internal/push"
)

var version = "dev"

func main() {
	os.Exit(run())
}

func run() int {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println("tug-server", version)
		return 0
	}
	settings, err := config.Load(os.Args[1:], os.LookupEnv)
	if errors.Is(err, flag.ErrHelp) {
		fmt.Println(`Tug: lightweight, headless HTTP/WebSocket push server

Usage: tug-server [--config server.yaml] [options]
  --listen host:port              default :16640
  --log-level debug|info|warn|error default info
  --log-messages=true|false         default true; logs accepted message data
  --heartbeat-interval duration    default 120s
  --max-clients count              default 32
  --client-queue-size count        default 16
  --client-queue-bytes bytes       default 65536
  --send-rate-limit count          default 10/second, burst 20
  --send-token / --receive-token   prefer TUG_SEND_TOKEN / TUG_RECEIVE_TOKEN
  --help / --version

Precedence: flags > TUG_* environment > YAML > defaults.
Distinct send/receive tokens (2+ printable ASCII bytes without spaces) are required.
No token-specific maximum; HTTP header/configuration size limits still apply.
Disable message data logs with --log-messages=false or TUG_LOG_MESSAGES=false.
Production requires HTTPS/WSS via a reverse proxy.`)
		return 0
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "configuration error:", err)
		return 2
	}
	var level slog.Level
	level.UnmarshalText([]byte(settings.LogLevel))
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	service, err := push.New(settings, logger)
	if err != nil {
		logger.Error("cannot initialize server")
		return 1
	}
	httpServer := service.HTTPServer()
	httpServer.ErrorLog = log.New(os.Stderr, "http: ", 0)
	listener, err := service.Listen()
	if err != nil {
		logger.Error("cannot bind listen address", "error", err)
		return 1
	}
	fmt.Fprintln(os.Stderr, "tug-server listening on", listener.Addr(), "(HTTP/WS; use TLS proxy for production)")
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- httpServer.Serve(listener)
	}()
	select {
	case <-ctx.Done():
	case err := <-serveResult:
		if !errors.Is(err, http.ErrServerClosed) {
			logger.Error("HTTP server stopped unexpectedly", "error", err)
			service.Close(context.Background())
			return 1
		}
	}
	stop()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	websocketError := service.Close(shutdownCtx)
	httpError := httpServer.Shutdown(shutdownCtx)
	if websocketError != nil || httpError != nil {
		httpServer.Close()
		logger.Error("shutdown deadline exceeded")
		return 1
	}
	return 0
}
