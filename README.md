# Tug

Tug is a lightweight, self-hosted push notification system. Its server accepts messages over HTTP and delivers them over WebSocket to connected clients.

- Windows client with tray integration and desktop notifications.
- Android client with a foreground receiver, notifications, and recent-message history.
- Separate tokens for sending and receiving messages.
- No server-side database or offline storage: only connected clients receive messages.

## Server Deployment

### Start with Docker Compose

On a server with Git, Docker, and Docker Compose installed:

```bash
git clone https://github.com/NiyahIsFine/tug.git
cd tug/deploy
cp .env.example .env
chmod 600 .env
```

Edit `.env` and set `TUG_SEND_TOKEN` and `TUG_RECEIVE_TOKEN` to two different, long random tokens without spaces.

Start the server:

```bash
docker compose up -d
```

### Remote Access

Use `http://<server-ip>:16640` on a trusted network and allow port `16640` through your firewall if needed.

## Send a Push

First, configure a Windows or Android client with your server address and **receive token**, then start receiving. Use the **send token** for HTTP requests.

Run this example on the server host, replacing the token with the one configured in `.env`:

```bash
export TUG_SEND_TOKEN='your-server-send-token'
curl --fail-with-body http://127.0.0.1:16640/api/v1/messages \
  -H "Authorization: Bearer $TUG_SEND_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Test","body":"Hello from Tug!"}'
```

When sending from another machine, replace `http://127.0.0.1:16640` with your server's HTTPS address. Messages are not stored for disconnected clients or replayed when they reconnect.
