# Tahap 1: Build binary Go
FROM golang:1.22-alpine AS builder
WORKDIR /app

# Copy shared library dan source code aggregator
COPY shared/ /shared/
COPY services/aggregator/ /app/

# Download dependensi dan compile binary statis (tanpa CGO)
RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /aggregator ./src/main.go

# Tahap 2: Runtime image minimal menggunakan Alpine
FROM alpine:latest
WORKDIR /root/

# Install CA Certificates (untuk HTTP request) dan wget (untuk healthcheck container)
RUN apk --no-cache add ca-certificates wget

# Copy binary terkompilasi dari builder
COPY --from=builder /aggregator .

EXPOSE 8083

# Jalankan service aggregator
CMD ["./aggregator"]
