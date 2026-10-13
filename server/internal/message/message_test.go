package message

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestParseUnicodeAndUTC(t *testing.T) {
	now := time.Date(2026, 10, 10, 12, 0, 1, 0, time.UTC)
	parsed, err := Parse([]byte(`{"title":"  Alert😀  ","body":"Download complete\nFile saved","timestamp":"2026-10-10T20:00:00+08:00"}`), now)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Title != "Alert😀" || parsed.Body != "Download complete\nFile saved" || parsed.Timestamp.Format(time.RFC3339) != "2026-10-10T12:00:00Z" || !parsed.ReceivedAt.Equal(now) {
		t.Fatalf("incorrect normalization: %+v", parsed)
	}
	parsed, err = Parse([]byte(`{"title":"Alert","body":"Done"}`), now)
	if err != nil || !parsed.Timestamp.Equal(now) {
		t.Fatalf("default timestamp: %+v, %v", parsed, err)
	}
	contents, err := json.Marshal(map[string]string{"title": strings.Repeat("😀", 120), "body": strings.Repeat("€", 4096)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Parse(contents, now); err != nil {
		t.Fatalf("Unicode code point boundary rejected: %v", err)
	}
}

func TestRejectInvalidMessages(t *testing.T) {
	cases := []string{
		`null`, `[]`, `{}`, `{"title":"Alert"}`, `{"title":" ","body":"Done"}`,
		`{"title":"Alert","body":" \n "}`, `{"title":1,"body":"Done"}`,
		`{"title":"Alert","body":"Done","unknown":1}`, `{"title":"Alert","body":"Done"} {}`,
		`{"title":"Alert","body":"Done","timestamp":"yesterday"}`,
		`{"title":"Alert","body":"Done","timestamp":null}`,
		`{"title":"Alert","body":"Done","timestamp":123}`,
		`{"title":"` + strings.Repeat("€", 121) + `","body":"Done"}`,
		`{"title":"Alert","body":"` + strings.Repeat("€", 4097) + `"}`,
		strings.Repeat(" ", MaxRequestBytes+1), string([]byte{'{', 0xff, '}'}),
	}
	for _, contents := range cases {
		if _, err := Parse([]byte(contents), time.Now()); err == nil {
			t.Fatalf("invalid input accepted (length %d)", len(contents))
		}
	}
}

func TestUniqueUUIDs(t *testing.T) {
	seen := make(map[string]bool)
	for index := 0; index < 1000; index++ {
		identifier, err := NewID()
		if err != nil || len(identifier) != 36 || identifier[14] != '4' || seen[identifier] {
			t.Fatalf("invalid/duplicate ID: %q, %v", identifier, err)
		}
		seen[identifier] = true
	}
}
