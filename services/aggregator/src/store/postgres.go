package store

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/grwna/IF4031-AAT-AkuAdalahBMKG/services/aggregator/src/domain"
)


type FilterParams struct {
	Type     string    
	Source   string    
	Severity []string  
	Since    time.Time 
	Until    time.Time 
	Limit    int       
	Cursor   string    
}

type PostgresStore struct {
	db *sql.DB
}

// NewPostgresStore membuat instance koneksi PostgreSQL dan menjalankan inisialisasi DDL
func NewPostgresStore(dbURL string) (*PostgresStore, error) {
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		return nil, fmt.Errorf("gagal membuka koneksi database: %w", err)
	}

	// Konfigurasi connection pool
	db.SetMaxOpenConns(100)
	db.SetMaxIdleConns(25)
	db.SetConnMaxLifetime(15 * time.Minute)

	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("gagal ping database: %w", err)
	}

	store := &PostgresStore{db: db}
	if err := store.InitSchema(context.Background()); err != nil {
		return nil, fmt.Errorf("gagal inisialisasi skema database: %w", err)
	}

	return store, nil
}

func (s *PostgresStore) Close() error {
	return s.db.Close()
}

// InitSchema 
func (s *PostgresStore) InitSchema(ctx context.Context) error {
	query := `
	CREATE TABLE IF NOT EXISTS hazard_events (
		hazard_id VARCHAR(255) PRIMARY KEY,
		source VARCHAR(50) NOT NULL,
		source_ref_id VARCHAR(255) NOT NULL,
		hazard_type VARCHAR(50) NOT NULL,
		severity VARCHAR(50) NOT NULL,
		area_name VARCHAR(255) NOT NULL,
		latitude DOUBLE PRECISION,
		longitude DOUBLE PRECISION,
		occurred_at TIMESTAMPTZ NOT NULL,
		ingested_at TIMESTAMPTZ NOT NULL,
		attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
		is_published BOOLEAN NOT NULL DEFAULT FALSE
	);
	ALTER TABLE hazard_events ADD COLUMN IF NOT EXISTS is_published BOOLEAN NOT NULL DEFAULT FALSE;
	CREATE INDEX IF NOT EXISTS idx_hazard_events_cursor ON hazard_events (occurred_at DESC, hazard_id DESC);
	CREATE INDEX IF NOT EXISTS idx_hazard_events_unpublished ON hazard_events (is_published) WHERE is_published = FALSE;
	`
	_, err := s.db.ExecContext(ctx, query)
	return err
}

// menyimpan HazardEvent
func (s *PostgresStore) UpsertHazardEvent(ctx context.Context, event domain.HazardEvent) error {
	attrJSON, err := json.Marshal(event.Attributes)
	if err != nil {
		return fmt.Errorf("gagal marshal attributes: %w", err)
	}

	query := `
	INSERT INTO hazard_events (
		hazard_id, source, source_ref_id, hazard_type, severity, area_name,
		latitude, longitude, occurred_at, ingested_at, attributes, is_published
	) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, FALSE)
	ON CONFLICT (hazard_id) DO UPDATE SET
		is_published = CASE 
			WHEN hazard_events.severity IS DISTINCT FROM EXCLUDED.severity 
			  OR hazard_events.attributes IS DISTINCT FROM EXCLUDED.attributes 
			THEN FALSE 
			ELSE hazard_events.is_published 
		END,
		severity = EXCLUDED.severity,
		area_name = EXCLUDED.area_name,
		latitude = EXCLUDED.latitude,
		longitude = EXCLUDED.longitude,
		occurred_at = EXCLUDED.occurred_at,
		ingested_at = EXCLUDED.ingested_at,
		attributes = EXCLUDED.attributes;
	`
	_, err = s.db.ExecContext(ctx, query,
		event.HazardID,
		event.Source,
		event.SourceRefID,
		event.HazardType,
		event.Severity,
		event.AreaName,
		event.Latitude,
		event.Longitude,
		event.OccurredAt,
		event.IngestedAt,
		string(attrJSON),
	)
	return err
}

// HazardEvent berdasarkan hazard_id
func (s *PostgresStore) GetHazardByID(ctx context.Context, hazardID string) (*domain.HazardEvent, error) {
	query := `
	SELECT hazard_id, source, source_ref_id, hazard_type, severity, area_name,
	       latitude, longitude, occurred_at, ingested_at, attributes
	FROM hazard_events
	WHERE hazard_id = $1;
	`
	row := s.db.QueryRowContext(ctx, query, hazardID)

	var h domain.HazardEvent
	var attrJSON string
	err := row.Scan(
		&h.HazardID, &h.Source, &h.SourceRefID, &h.HazardType, &h.Severity, &h.AreaName,
		&h.Latitude, &h.Longitude, &h.OccurredAt, &h.IngestedAt, &attrJSON,
	)
	if err == sql.ErrNoRows {
		return nil, nil // Not found
	}
	if err != nil {
		return nil, err
	}

	if err := json.Unmarshal([]byte(attrJSON), &h.Attributes); err != nil {
		h.Attributes = make(map[string]any)
	}

	return &h, nil
}

// get data pakai filtering dan Keyset Pagination (Cursor)
func (s *PostgresStore) GetHazards(ctx context.Context, filter FilterParams) ([]domain.HazardEvent, string, error) {
	var whereClauses []string
	var args []any
	argID := 1

	var cursorOccurredAt time.Time
	var cursorHazardID string
	if filter.Cursor != "" {
		cursorBytes, err := base64.RawURLEncoding.DecodeString(filter.Cursor)
		if err != nil {
			cursorBytes, err = base64.URLEncoding.DecodeString(filter.Cursor)
			if err != nil {
				return nil, "", fmt.Errorf("INVALID_CURSOR")
			}
		}
		var payload domain.CursorPayload
		if err := json.Unmarshal(cursorBytes, &payload); err != nil {
			return nil, "", fmt.Errorf("INVALID_CURSOR")
		}
		cursorOccurredAt = payload.OccurredAt
		cursorHazardID = payload.HazardID

		whereClauses = append(whereClauses, fmt.Sprintf("(occurred_at, hazard_id) < ($%d, $%d)", argID, argID+1))
		args = append(args, cursorOccurredAt, cursorHazardID)
		argID += 2
	}

	// Filter Type
	if filter.Type != "" {
		whereClauses = append(whereClauses, fmt.Sprintf("hazard_type = $%d", argID))
		args = append(args, strings.ToUpper(filter.Type))
		argID++
	}

	// Filter Source
	if filter.Source != "" {
		whereClauses = append(whereClauses, fmt.Sprintf("source = $%d", argID))
		args = append(args, strings.ToUpper(filter.Source))
		argID++
	}

	// Filter Severity (mis. "SIAGA,AWAS")
	if len(filter.Severity) > 0 {
		var sevPlaceholders []string
		for _, sev := range filter.Severity {
			sevPlaceholders = append(sevPlaceholders, fmt.Sprintf("$%d", argID))
			args = append(args, strings.ToUpper(strings.TrimSpace(sev)))
			argID++
		}
		whereClauses = append(whereClauses, fmt.Sprintf("severity IN (%s)", strings.Join(sevPlaceholders, ",")))
	}

	// Filter Since
	if !filter.Since.IsZero() {
		whereClauses = append(whereClauses, fmt.Sprintf("occurred_at >= $%d", argID))
		args = append(args, filter.Since)
		argID++
	}

	// Filter Until
	if !filter.Until.IsZero() {
		whereClauses = append(whereClauses, fmt.Sprintf("occurred_at < $%d", argID))
		args = append(args, filter.Until)
		argID++
	}

	// Susun query 
	query := `
	SELECT hazard_id, source, source_ref_id, hazard_type, severity, area_name,
	       latitude, longitude, occurred_at, ingested_at, attributes
	FROM hazard_events
	`
	if len(whereClauses) > 0 {
		query += " WHERE " + strings.Join(whereClauses, " AND ")
	}
	query += fmt.Sprintf(" ORDER BY occurred_at DESC, hazard_id DESC LIMIT $%d", argID)

	limit := filter.Limit
	if limit <= 0 {
		limit = 50
	} else if limit > 200 {
		limit = 200
	}
	args = append(args, limit)

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()

	var events []domain.HazardEvent
	for rows.Next() {
		var h domain.HazardEvent
		var attrJSON string
		if err := rows.Scan(
			&h.HazardID, &h.Source, &h.SourceRefID, &h.HazardType, &h.Severity, &h.AreaName,
			&h.Latitude, &h.Longitude, &h.OccurredAt, &h.IngestedAt, &attrJSON,
		); err != nil {
			return nil, "", err
		}
		if err := json.Unmarshal([]byte(attrJSON), &h.Attributes); err != nil {
			h.Attributes = make(map[string]any)
		}
		events = append(events, h)
	}

	if err := rows.Err(); err != nil {
		return nil, "", err
	}

	// Hitung next_cursor jika hasil limit
	var nextCursor string
	if len(events) == limit {
		lastItem := events[len(events)-1]
		payload := domain.CursorPayload{
			OccurredAt: lastItem.OccurredAt,
			HazardID:   lastItem.HazardID,
		}
		payloadBytes, _ := json.Marshal(payload)
		nextCursor = base64.RawURLEncoding.EncodeToString(payloadBytes)
	}

	return events, nextCursor, nil
}

// HazardEvent yang belum berhasil dipublish (is_published = FALSE)
func (s *PostgresStore) GetUnpublishedEvents(ctx context.Context) ([]domain.HazardEvent, error) {
	query := `
	SELECT hazard_id, source, source_ref_id, hazard_type, severity, area_name,
	       latitude, longitude, occurred_at, ingested_at, attributes, is_published
	FROM hazard_events
	WHERE is_published = FALSE
	ORDER BY occurred_at ASC;
	`
	rows, err := s.db.QueryContext(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []domain.HazardEvent
	for rows.Next() {
		var h domain.HazardEvent
		var attrJSON string
		if err := rows.Scan(
			&h.HazardID, &h.Source, &h.SourceRefID, &h.HazardType, &h.Severity, &h.AreaName,
			&h.Latitude, &h.Longitude, &h.OccurredAt, &h.IngestedAt, &attrJSON, &h.IsPublished,
		); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(attrJSON), &h.Attributes); err != nil {
			h.Attributes = make(map[string]any)
		}
		events = append(events, h)
	}

	return events, rows.Err()
}

func (s *PostgresStore) MarkAsPublished(ctx context.Context, hazardID string) error {
	query := `UPDATE hazard_events SET is_published = TRUE WHERE hazard_id = $1;`
	_, err := s.db.ExecContext(ctx, query, hazardID)
	return err
}
