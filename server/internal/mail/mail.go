// Package mail sends transactional email (sign-in codes) over SMTP.
package mail

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"mime"
	"mime/quotedprintable"
	"net"
	"net/mail"
	"net/smtp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Message struct {
	To      string
	Subject string
	Text    string
	HTML    string
}

type Sender interface {
	Send(ctx context.Context, m Message) error
}

// SMTPConfig is edited in the console. Security: "starttls" | "tls" | "none".
type SMTPConfig struct {
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Username string `json:"username"`
	Password string `json:"password"`
	From     string `json:"from"`
	Security string `json:"security"`
}

func (c SMTPConfig) Configured() bool { return c.Host != "" && c.From != "" }

var ErrNotConfigured = errors.New("email (SMTP) is not configured")

type SMTP struct{ Config SMTPConfig }

func (s SMTP) Send(ctx context.Context, m Message) error {
	c := s.Config
	if !c.Configured() {
		return ErrNotConfigured
	}
	from, err := mail.ParseAddress(c.From)
	if err != nil {
		return fmt.Errorf("invalid From address: %w", err)
	}
	port := c.Port
	if port == 0 {
		port = map[string]int{"tls": 465, "none": 25}[c.Security]
		if port == 0 {
			port = 587
		}
	}
	addr := net.JoinHostPort(c.Host, strconv.Itoa(port))
	dialer := &net.Dialer{Timeout: 15 * time.Second}
	tlsCfg := &tls.Config{ServerName: c.Host, MinVersion: tls.VersionTLS12}

	var conn net.Conn
	if c.Security == "tls" {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, tlsCfg)
	} else {
		conn, err = dialer.DialContext(ctx, "tcp", addr)
	}
	if err != nil {
		return fmt.Errorf("connect %s: %w", addr, err)
	}
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	} else {
		_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	}
	client, err := smtp.NewClient(conn, c.Host)
	if err != nil {
		conn.Close()
		return err
	}
	defer client.Close()
	if c.Security == "starttls" || c.Security == "" {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return errors.New("server does not support STARTTLS")
		}
		if err := client.StartTLS(tlsCfg); err != nil {
			return fmt.Errorf("starttls: %w", err)
		}
	}
	if c.Username != "" {
		if err := client.Auth(smtp.PlainAuth("", c.Username, c.Password, c.Host)); err != nil {
			return fmt.Errorf("auth: %w", err)
		}
	}
	if err := client.Mail(from.Address); err != nil {
		return err
	}
	if err := client.Rcpt(m.To); err != nil {
		return err
	}
	w, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(build(from, m)); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return client.Quit()
}

func build(from *mail.Address, m Message) []byte {
	var b bytes.Buffer
	boundary := randHex(12)
	hdr := func(k, v string) { fmt.Fprintf(&b, "%s: %s\r\n", k, v) }
	hdr("From", from.String())
	hdr("To", m.To)
	hdr("Subject", mime.QEncoding.Encode("utf-8", m.Subject))
	hdr("Date", time.Now().Format(time.RFC1123Z))
	hdr("Message-ID", fmt.Sprintf("<%s@%s>", randHex(16), domainOf(from.Address)))
	hdr("MIME-Version", "1.0")
	hdr("Content-Type", `multipart/alternative; boundary="`+boundary+`"`)
	b.WriteString("\r\n")
	part := func(ctype, body string) {
		fmt.Fprintf(&b, "--%s\r\nContent-Type: %s; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n", boundary, ctype)
		qp := quotedprintable.NewWriter(&b)
		_, _ = qp.Write([]byte(body))
		_ = qp.Close()
		b.WriteString("\r\n")
	}
	part("text/plain", m.Text)
	if m.HTML != "" {
		part("text/html", m.HTML)
	}
	fmt.Fprintf(&b, "--%s--\r\n", boundary)
	return b.Bytes()
}

func randHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func domainOf(addr string) string {
	if i := strings.LastIndex(addr, "@"); i >= 0 {
		return addr[i+1:]
	}
	return "localhost"
}

// Log prints messages instead of sending them (development).
type Log struct{}

func (Log) Send(_ context.Context, m Message) error {
	slog.Warn("DEV MAIL (not sent)", "to", m.To, "subject", m.Subject, "text", m.Text)
	return nil
}

// Recorder keeps sent messages in memory (tests).
type Recorder struct {
	mu   sync.Mutex
	sent []Message
}

func (r *Recorder) Send(_ context.Context, m Message) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sent = append(r.sent, m)
	return nil
}

// Last returns the latest message sent to [to].
func (r *Recorder) Last(to string) (Message, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := len(r.sent) - 1; i >= 0; i-- {
		if r.sent[i].To == to {
			return r.sent[i], true
		}
	}
	return Message{}, false
}
