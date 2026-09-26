FROM golang:1.22-alpine AS builder
WORKDIR /app

COPY shared/ /shared/
COPY services/bmkg-mock/ /app/

RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -o /bmkg-mock src/main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /bmkg-mock .
EXPOSE 8081
CMD ["./bmkg-mock"]
