import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request


def request(base, path, token=None, message=None):
    headers = {} if token is None else {"Authorization": f"Bearer {token}"}
    data = None if message is None else json.dumps(message).encode()
    if data is not None:
        headers["Content-Type"] = "application/json"
    try:
        with urllib.request.urlopen(urllib.request.Request(base + path, data=data, headers=headers), timeout=5) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def read_exact(connection, size):
    contents = b""
    while len(contents) < size:
        chunk = connection.recv(size - len(contents))
        if not chunk:
            raise RuntimeError("Unexpected WebSocket EOF")
        contents += chunk
    return contents


def frame(connection):
    header = read_exact(connection, 2)
    if header[0] != 0x81 or header[1] & 0x80:
        raise RuntimeError("Expected unmasked complete text frame")
    size = header[1] & 0x7F
    if size == 126:
        size = struct.unpack("!H", read_exact(connection, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(connection, 8))[0]
    if size > 32768:
        raise RuntimeError("Unexpected oversized frame")
    return json.loads(read_exact(connection, size))


def check(base, send_token, receive_token):
    address = urllib.parse.urlparse(base)
    if address.scheme != "http" or address.hostname not in ("127.0.0.1", "localhost"):
        raise RuntimeError("Smoke test only supports loopback HTTP")
    if request(base, "/healthz") != (200, {"status": "ok"}):
        raise RuntimeError("Health endpoint failed")
    for token in (None, "invalid-smoke-token", receive_token):
        if request(base, "/api/v1/messages", token, {"title": "smoke", "body": "denied"})[0] != 401:
            raise RuntimeError("Sending accepted without the send credential")
    for token in (None, "invalid-smoke-token", send_token):
        if request(base, "/api/v1/ws", token)[0] != 401:
            raise RuntimeError("WebSocket accepted without the receive credential")
    with socket.create_connection((address.hostname, address.port or 80), timeout=5) as connection:
        key = base64.b64encode(os.urandom(16)).decode()
        handshake = (f"GET /api/v1/ws HTTP/1.1\r\nHost: {address.netloc}\r\nUpgrade: websocket\r\n"
                     f"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n"
                     f"Authorization: Bearer {receive_token}\r\n\r\n")
        connection.sendall(handshake.encode())
        headers = b""
        while not headers.endswith(b"\r\n\r\n"):
            headers += read_exact(connection, 1)
            if len(headers) > 8192:
                raise RuntimeError("Oversized handshake")
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if not headers.startswith(b"HTTP/1.1 101 ") or accept.encode() not in headers:
            raise RuntimeError("WebSocket handshake failed")
        if frame(connection)["type"] != "hello":
            raise RuntimeError("Missing hello frame")
        body = "smoke-sensitive-body-not-for-logs"
        status, accepted = request(base, "/api/v1/messages", send_token, {"title": "smoke", "body": body})
        if status != 202 or accepted["queued_clients"] != 1:
            raise RuntimeError("Authenticated message was not queued")
        received = frame(connection)
        if received["type"] != "message" or received["message"]["id"] != accepted["id"] or received["message"]["body"] != body:
            raise RuntimeError("Message broadcast mismatch")
    print("Health, send/receive separation, HTTP 202 and WebSocket broadcast passed")


def image_check(image, platform):
    send_token, receive_token = "smoke-send-test-only", "smoke-receive-test-only"
    command = ["docker", "run", "--detach", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges:true",
               "--platform", platform, "--publish", "127.0.0.1::16640", "--env", f"TUG_SEND_TOKEN={send_token}",
               "--env", f"TUG_RECEIVE_TOKEN={receive_token}", "--env", "TUG_LOG_MESSAGES=false", image]
    container = subprocess.check_output(command, text=True).strip()
    try:
        port = subprocess.check_output(["docker", "port", container, "16640/tcp"], text=True).strip()
        base = "http://" + port
        for attempt in range(30):
            try:
                if request(base, "/healthz")[0] == 200:
                    break
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(1)
        else:
            raise RuntimeError("Container did not become ready")
        check(base, send_token, receive_token)
        logs = subprocess.check_output(["docker", "logs", container], text=True, stderr=subprocess.STDOUT)
        if any(value in logs for value in (send_token, receive_token, "smoke-sensitive-body-not-for-logs")):
            raise RuntimeError("Sensitive value leaked to logs")
    finally:
        subprocess.run(["docker", "rm", "--force", container], check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--image")
    mode.add_argument("--url")
    parser.add_argument("--platform", default="linux/amd64")
    arguments = parser.parse_args()
    if arguments.image:
        image_check(arguments.image, arguments.platform)
    else:
        check(arguments.url.rstrip("/"), os.environ["TUG_SEND_TOKEN"], os.environ["TUG_RECEIVE_TOKEN"])
