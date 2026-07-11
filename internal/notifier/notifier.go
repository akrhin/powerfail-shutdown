// Package notifier handles Telegram notifications.
package notifier

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"github.com/akrhin/powerfail-shutdown/internal/models"
)

// Notifier sends alert messages.
type Notifier struct {
	cfg        *models.TelegramConfig
	httpClient *http.Client
}

// New creates a Notifier from config. Returns nil if Telegram is not configured.
func New(cfg *models.TelegramConfig) *Notifier {
	if cfg == nil || cfg.BotToken == "" || cfg.ChatID == 0 {
		return nil
	}
	return &Notifier{
		cfg: cfg,
		httpClient: &http.Client{
			Timeout: 15 * time.Second,
			Transport: &http.Transport{
				Proxy: proxyFromConfig(cfg.Proxy),
			},
		},
	}
}

func proxyFromConfig(proxy string) func(*http.Request) (*url.URL, error) {
	if proxy == "" {
		return nil
	}
	proxyURL, err := url.Parse(proxy)
	if err != nil {
		return nil // invalid proxy URL, fallback to direct
	}
	return http.ProxyURL(proxyURL)
}

// SendMarkdown sends a Markdown-formatted message to the configured Telegram chat.
func (n *Notifier) SendMarkdown(ctx context.Context, text string) error {
	if n == nil {
		return nil
	}
	return n.send(ctx, text, "Markdown")
}

// SendPlain sends a plain text message.
func (n *Notifier) SendPlain(ctx context.Context, text string) error {
	if n == nil {
		return nil
	}
	return n.send(ctx, text, "")
}

type tgPayload struct {
	ChatID                int64  `json:"chat_id"`
	Text                  string `json:"text"`
	ParseMode             string `json:"parse_mode,omitempty"`
	DisableWebPagePreview bool   `json:"disable_web_page_preview"`
}

func (n *Notifier) send(ctx context.Context, text string, parseMode string) error {
	payload := tgPayload{
		ChatID:                n.cfg.ChatID,
		Text:                  text,
		ParseMode:             parseMode,
		DisableWebPagePreview: true,
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}

	url := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", n.cfg.BotToken)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := n.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("telegram returned %d", resp.StatusCode)
	}
	return nil
}
