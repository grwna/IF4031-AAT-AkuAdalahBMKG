FROM golang:1.22-alpine AS builder
WORKDIR /app

COPY shared/ /shared/
COPY services/consumer-dashboard/ /app/

RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -o /consumer-dashboard src/main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /consumer-dashboard .
EXPOSE 8085
CMD ["./consumer-dashboard"]
