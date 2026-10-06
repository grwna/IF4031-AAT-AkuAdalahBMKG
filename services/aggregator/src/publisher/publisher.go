package publisher

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/domain"
)

const confirmTimeout = 5 * time.Second

// Publisher mengelola koneksi dan pengiriman pesan ke RabbitMQ Exchange
type Publisher struct {
	url      string
	exchange string
	logger   *slog.Logger

	mu        sync.RWMutex
	conn      *amqp.Connection
	ch        *amqp.Channel
	connected bool
}

// NewPublisher membuat instance Publisher baru
func NewPublisher(url, exchange string, logger *slog.Logger) *Publisher {
	return &Publisher{
		url:      url,
		exchange: exchange,
		logger:   logger,
	}
}

// StartLoop menjalankan loop penanganan koneksi dan reconnect otomatis di background
func (p *Publisher) StartLoop(ctx context.Context) {
	if p.url == "" {
		p.logger.Warn("RABBITMQ_URL tidak dikonfigurasi, publisher RabbitMQ tidak aktif")
		return
	}

	backoff := 1 * time.Second
	maxBackoff := 15 * time.Second

	for {
		select {
		case <-ctx.Done():
			p.logger.Info("Publisher loop dihentikan secara graceful")
			p.Close()
			return
		default:
		}

		if err := p.connect(); err != nil {
			p.logger.Error("Gagal terhubung ke RabbitMQ message-broker",
				slog.String("error", err.Error()),
				slog.Duration("retry_in", backoff),
			)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
				backoff *= 2
				if backoff > maxBackoff {
					backoff = maxBackoff
				}
				continue
			}
		}

		// Reset backoff jika berhasil terhubung
		backoff = 1 * time.Second
		p.logger.Info("Terhubung ke RabbitMQ message-broker", slog.String("exchange", p.exchange))

		// Dengarkan notifikasi jika koneksi atau channel terputus
		connClose := p.conn.NotifyClose(make(chan *amqp.Error, 1))
		chanClose := p.ch.NotifyClose(make(chan *amqp.Error, 1))

		select {
		case <-ctx.Done():
			p.logger.Info("Publisher dihentikan oleh context")
			p.Close()
			return
		case err := <-connClose:
			p.setConnected(false)
			if err != nil {
				p.logger.Warn("Koneksi RabbitMQ terputus", slog.String("error", err.Error()))
			}
		case err := <-chanClose:
			p.setConnected(false)
			if err != nil {
				p.logger.Warn("Channel RabbitMQ terputus", slog.String("error", err.Error()))
			}
		}
	}
}

// connect menginisialisasi koneksi AMQP, channel, deklarasi exchange topic, dan mode publisher confirm
func (p *Publisher) connect() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	// Tutup koneksi lama jika ada
	if p.ch != nil {
		_ = p.ch.Close()
	}
	if p.conn != nil {
		_ = p.conn.Close()
	}
	p.connected = false

	// Dial ke RabbitMQ
	conn, err := amqp.Dial(p.url)
	if err != nil {
		return fmt.Errorf("dial amqp: %w", err)
	}

	ch, err := conn.Channel()
	if err != nil {
		_ = conn.Close()
		return fmt.Errorf("open channel: %w", err)
	}

	// Deklarasi exchange topic (durable=true, autoDelete=false, internal=false)
	if err := ch.ExchangeDeclare(p.exchange, "topic", true, false, false, false, nil); err != nil {
		_ = ch.Close()
		_ = conn.Close()
		return fmt.Errorf("declare exchange: %w", err)
	}

	// Aktifkan mode Publisher Confirm
	if err := ch.Confirm(false); err != nil {
		_ = ch.Close()
		_ = conn.Close()
		return fmt.Errorf("enable confirm mode: %w", err)
	}

	p.conn = conn
	p.ch = ch
	p.connected = true
	return nil
}

func (p *Publisher) setConnected(status bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.connected = status
}

// IsConnected mengecek apakah publisher saat ini terhubung ke broker
func (p *Publisher) IsConnected() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.connected
}

// Publish mengirimkan HazardEvent ke RabbitMQ Exchange sesuai spesifikasi kontrak §3.2 & §7
func (p *Publisher) Publish(ctx context.Context, ev domain.HazardEvent, correlationID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if !p.connected || p.ch == nil {
		return errors.New("publisher tidak terhubung ke message-broker")
	}

	body, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("marshal event: %w", err)
	}

	pubCtx, cancel := context.WithTimeout(ctx, confirmTimeout)
	defer cancel()

	routingKey := strings.ToLower(ev.HazardType)
	messageID := ev.HazardID + ":" + ev.Severity

	dc, err := p.ch.PublishWithDeferredConfirmWithContext(pubCtx, p.exchange, routingKey, false, false,
		amqp.Publishing{
			ContentType:   "application/json",
			DeliveryMode:  amqp.Persistent,
			MessageId:     messageID,
			CorrelationId: correlationID,
			Timestamp:     time.Now().UTC(),
			Type:          "HazardEvent",
			AppId:         "aggregator",
			Body:          body,
		})
	if err != nil {
		return fmt.Errorf("publish message: %w", err)
	}

	// Tunggu konfirmasi (ack/nack) dari broker
	acked, err := dc.WaitContext(pubCtx)
	if err != nil {
		return fmt.Errorf("wait confirm: %w", err)
	}
	if !acked {
		return errors.New("broker membalas nack (message nacked)")
	}

	return nil
}

// Close menutup channel dan koneksi AMQP
func (p *Publisher) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()

	p.connected = false
	if p.ch != nil {
		_ = p.ch.Close()
		p.ch = nil
	}
	if p.conn != nil {
		_ = p.conn.Close()
		p.conn = nil
	}
}
