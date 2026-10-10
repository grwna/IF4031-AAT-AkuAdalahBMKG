FROM golang:1.22-alpine AS builder
WORKDIR /app

COPY shared/ /shared/
COPY services/consumer-notifier/ /app/

RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -o /consumer-notifier src/main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /consumer-notifier .
EXPOSE 8086
CMD ["./consumer-notifier"]
