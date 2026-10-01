FROM golang:1.22-alpine AS builder
WORKDIR /app

COPY shared/ /shared/
COPY services/auth-service/ /app/

RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -o /auth-service src/main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /auth-service .
EXPOSE 8084
CMD ["./auth-service"]
