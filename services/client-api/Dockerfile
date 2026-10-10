FROM golang:1.22-alpine AS builder
WORKDIR /app

COPY shared/ /shared/
COPY services/client-api/ /app/

RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -o /client-api src/main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /client-api .
EXPOSE 8080
CMD ["./client-api"]
