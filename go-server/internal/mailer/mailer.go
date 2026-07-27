package mailer

import (
	"crypto/tls"
	"fmt"
	"net"
	"net/mail"
	"net/smtp"
	"strings"
	"time"

	"go-server/internal/config"
)

type Mailer struct {
	config config.Mail
}

func New(cfg config.Mail) *Mailer {
	return &Mailer{config: cfg}
}

func (m *Mailer) Enabled() bool {
	return m != nil && m.config.Enabled
}

func (m *Mailer) SendReviewResult(
	recipient string,
	gameName string,
	approved bool,
	reason string,
) error {
	if !m.Enabled() {
		return nil
	}
	recipientAddress, err := mail.ParseAddress(recipient)
	if err != nil {
		return fmt.Errorf("收件邮箱无效: %w", err)
	}
	subject := "Playmesh 游戏包审核结果"
	status := "已通过"
	if !approved {
		status = "未通过"
	}
	body := fmt.Sprintf(
		"游戏：%s\r\n审核结果：%s\r\n说明：%s\r\n",
		sanitizeHeader(gameName), status, reason,
	)
	from, err := mail.ParseAddress(m.config.From)
	if err != nil {
		return err
	}
	message := []byte(
		"From: " + sanitizeHeader(m.config.From) + "\r\n" +
			"To: " + sanitizeHeader(recipientAddress.Address) + "\r\n" +
			"Subject: " + subject + "\r\n" +
			"MIME-Version: 1.0\r\n" +
			"Content-Type: text/plain; charset=UTF-8\r\n" +
			"\r\n" + body,
	)
	address := net.JoinHostPort(m.config.Host, fmt.Sprintf("%d", m.config.Port))
	var auth smtp.Auth
	if m.config.Username != "" {
		auth = smtp.PlainAuth("", m.config.Username, m.config.Password, m.config.Host)
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var connection net.Conn
	if m.config.UseTLS {
		connection, err = tls.DialWithDialer(dialer, "tcp", address, &tls.Config{
			MinVersion: tls.VersionTLS12,
			ServerName: m.config.Host,
		})
	} else {
		connection, err = dialer.Dial("tcp", address)
	}
	if err != nil {
		return err
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(30 * time.Second)); err != nil {
		return err
	}
	client, err := smtp.NewClient(connection, m.config.Host)
	if err != nil {
		return err
	}
	defer client.Close()
	if auth != nil {
		if err := client.Auth(auth); err != nil {
			return err
		}
	}
	if err := client.Mail(from.Address); err != nil {
		return err
	}
	if err := client.Rcpt(recipientAddress.Address); err != nil {
		return err
	}
	writer, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := writer.Write(message); err != nil {
		_ = writer.Close()
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}
	return client.Quit()
}

func (m *Mailer) SendEmailVerification(recipient string, verificationURL string) error {
	if !m.Enabled() {
		return nil
	}
	recipientAddress, err := mail.ParseAddress(recipient)
	if err != nil {
		return fmt.Errorf("收件邮箱无效: %w", err)
	}
	from, err := mail.ParseAddress(m.config.From)
	if err != nil {
		return err
	}
	message := []byte(
		"From: " + sanitizeHeader(m.config.From) + "\r\n" +
			"To: " + sanitizeHeader(recipientAddress.Address) + "\r\n" +
			"Subject: Playmesh 邮箱验证\r\n" +
			"MIME-Version: 1.0\r\n" +
			"Content-Type: text/plain; charset=UTF-8\r\n\r\n" +
			"请在 24 小时内打开以下链接完成邮箱验证：\r\n" +
			sanitizeHeader(verificationURL) + "\r\n",
	)
	address := net.JoinHostPort(m.config.Host, fmt.Sprintf("%d", m.config.Port))
	var auth smtp.Auth
	if m.config.Username != "" {
		auth = smtp.PlainAuth("", m.config.Username, m.config.Password, m.config.Host)
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var connection net.Conn
	if m.config.UseTLS {
		connection, err = tls.DialWithDialer(dialer, "tcp", address, &tls.Config{
			MinVersion: tls.VersionTLS12,
			ServerName: m.config.Host,
		})
	} else {
		connection, err = dialer.Dial("tcp", address)
	}
	if err != nil {
		return err
	}
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(30 * time.Second)); err != nil {
		return err
	}
	client, err := smtp.NewClient(connection, m.config.Host)
	if err != nil {
		return err
	}
	defer client.Close()
	if auth != nil {
		if err := client.Auth(auth); err != nil {
			return err
		}
	}
	if err := client.Mail(from.Address); err != nil {
		return err
	}
	if err := client.Rcpt(recipientAddress.Address); err != nil {
		return err
	}
	writer, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := writer.Write(message); err != nil {
		_ = writer.Close()
		return err
	}
	if err := writer.Close(); err != nil {
		return err
	}
	return client.Quit()
}

func sanitizeHeader(value string) string {
	return strings.NewReplacer("\r", "", "\n", "").Replace(value)
}
