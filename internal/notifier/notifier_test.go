package notifier

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/akrhin/powerfail-shutdown/internal/models"
)

func TestNewReturnsNilWhenCfgIsNil(t *testing.T) {
	n := New(nil)
	if n != nil {
		t.Error("expected nil when config is nil")
	}
}

func TestNewReturnsNilWhenBotTokenEmpty(t *testing.T) {
	n := New(&models.TelegramConfig{BotToken: "", ChatID: 12345})
	if n != nil {
		t.Error("expected nil when BotToken is empty")
	}
}

func TestNewReturnsNilWhenChatIDZero(t *testing.T) {
	n := New(&models.TelegramConfig{BotToken: "bot123", ChatID: 0})
	if n != nil {
		t.Error("expected nil when ChatID is 0")
	}
}

func TestNewReturnsNotifier(t *testing.T) {
	n := New(&models.TelegramConfig{BotToken: "bot123", ChatID: 54321})
	if n == nil {
		t.Fatal("expected non-nil Notifier")
	}
}

func TestSendMarkdownNilNotifier(t *testing.T) {
	// Should not panic and return nil
	err := (*Notifier)(nil).SendMarkdown(context.Background(), "test")
	if err != nil {
		t.Fatal(err)
	}
}

func TestSendPlainNilNotifier(t *testing.T) {
	err := (*Notifier)(nil).SendPlain(context.Background(), "test")
	if err != nil {
		t.Fatal(err)
	}
}

func TestSendMarkdown(t *testing.T) {
	var receivedBody []byte
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"ok": true}`))
	}))
	defer ts.Close()

	// Replace the Telegram API URL by using the test server directly
	n := New(&models.TelegramConfig{BotToken: "bot:test", ChatID: 12345})
	if n == nil {
		t.Fatal("expected non-nil Notifier")
	}
	// Override the URL scheme by using the test server URL as a proxy trick
	// Actually we'll just test that the payload is correctly formed by using a custom httpClient
	// that replaces the URL. But New sets the URL internally. Let's test by intercepting via the HTTP transport.

	// Instead: create a notifier and replace its httpClient.Transport to point to our test server
	n.httpClient = &http.Client{
		Transport: &testRoundTripper{baseURL: ts.URL},
	}

	err := n.SendMarkdown(context.Background(), "*Hello* World")
	if err != nil {
		t.Fatal(err)
	}

	var payload tgPayload
	if err := json.Unmarshal(receivedBody, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.ChatID != 12345 {
		t.Errorf("expected ChatID 12345, got %d", payload.ChatID)
	}
	if payload.Text != "*Hello* World" {
		t.Errorf("expected text '*Hello* World', got %q", payload.Text)
	}
	if payload.ParseMode != "Markdown" {
		t.Errorf("expected Markdown parse mode, got %q", payload.ParseMode)
	}
	if !payload.DisableWebPagePreview {
		t.Error("expected web page preview disabled")
	}
}

func TestSendPlain(t *testing.T) {
	var receivedBody []byte
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"ok": true}`))
	}))
	defer ts.Close()

	n := &Notifier{
		cfg: &models.TelegramConfig{BotToken: "bot:test", ChatID: 12345},
		httpClient: &http.Client{
			Transport: &testRoundTripper{baseURL: ts.URL},
		},
	}

	err := n.SendPlain(context.Background(), "Hello World")
	if err != nil {
		t.Fatal(err)
	}

	var payload tgPayload
	if err := json.Unmarshal(receivedBody, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.ParseMode != "" {
		t.Errorf("expected empty parse mode for plain text, got %q", payload.ParseMode)
	}
}

func TestSendTelegramError(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		w.Write([]byte(`{"ok": false, "error_code": 403, "description": "Forbidden"}`))
	}))
	defer ts.Close()

	n := &Notifier{
		cfg: &models.TelegramConfig{BotToken: "bot:test", ChatID: 12345},
		httpClient: &http.Client{
			Transport: &testRoundTripper{baseURL: ts.URL},
		},
	}

	err := n.SendMarkdown(context.Background(), "test")
	if err == nil {
		t.Fatal("expected error from non-OK Telegram response")
	}
}

func TestProxyFromConfigEmpty(t *testing.T) {
	fn := proxyFromConfig("")
	if fn != nil {
		t.Error("expected nil proxy function for empty string")
	}
}

func TestProxyFromConfigValid(t *testing.T) {
	fn := proxyFromConfig("socks5://127.0.0.1:1080")
	if fn == nil {
		t.Fatal("expected non-nil proxy function for valid URL")
	}
}

func TestProxyFromConfigInvalid(t *testing.T) {
	fn := proxyFromConfig("://invalid")
	if fn != nil {
		t.Error("expected nil proxy function for invalid URL")
	}
}

// testRoundTripper rewrites requests to point at a test server.
type testRoundTripper struct {
	baseURL string
}

func (t *testRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	// Replace scheme/host with test server
	req.URL.Scheme = "http"
	req.URL.Host = t.baseURL[len("http://"):]
	return http.DefaultTransport.RoundTrip(req)
}
