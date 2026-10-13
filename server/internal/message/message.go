package message

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"
)

const MaxRequestBytes = 32 * 1024

type Message struct {
	ID         string    `json:"id"`
	Title      string    `json:"title"`
	Body       string    `json:"body"`
	Timestamp  time.Time `json:"timestamp"`
	ReceivedAt time.Time `json:"received_at"`
}

type requestFields struct {
	Title     string          `json:"title"`
	Body      string          `json:"body"`
	Timestamp json.RawMessage `json:"timestamp"`
}

func Parse(contents []byte, now time.Time) (Message, error) {
	if len(contents) > MaxRequestBytes || !utf8.Valid(contents) {
		return Message{}, errors.New("request must be UTF-8 JSON within 32 KiB")
	}
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	var fields requestFields
	if err := decoder.Decode(&fields); err != nil {
		return Message{}, errors.New("invalid JSON fields")
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return Message{}, errors.New("request must contain exactly one JSON object")
	}
	fields.Title = strings.TrimSpace(fields.Title)
	if utf8.RuneCountInString(fields.Title) < 1 || utf8.RuneCountInString(fields.Title) > 120 {
		return Message{}, errors.New("title must contain 1 to 120 Unicode code points")
	}
	if strings.TrimSpace(fields.Body) == "" || utf8.RuneCountInString(fields.Body) > 4096 {
		return Message{}, errors.New("body must be nonblank and contain at most 4096 Unicode code points")
	}
	timestamp := now.UTC()
	if len(fields.Timestamp) != 0 {
		var text string
		if bytes.Equal(fields.Timestamp, []byte("null")) || json.Unmarshal(fields.Timestamp, &text) != nil {
			return Message{}, errors.New("timestamp must be an RFC 3339 string")
		}
		parsed, err := time.Parse(time.RFC3339Nano, text)
		if err != nil {
			return Message{}, errors.New("timestamp must be an RFC 3339 string")
		}
		timestamp = parsed.UTC()
	}
	return Message{Title: fields.Title, Body: fields.Body, Timestamp: timestamp, ReceivedAt: now.UTC()}, nil
}

func NewID() (string, error) {
	var identifier [16]byte
	if _, err := rand.Read(identifier[:]); err != nil {
		return "", err
	}
	identifier[6] = identifier[6]&0x0f | 0x40
	identifier[8] = identifier[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", identifier[:4], identifier[4:6], identifier[6:8], identifier[8:10], identifier[10:]), nil
}
