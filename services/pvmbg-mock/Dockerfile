FROM golang:1.22-alpine AS builder
WORKDIR /app

COPY shared/ /shared/
COPY services/pvmbg-mock/ /app/

RUN go mod download
RUN CGO_ENABLED=0 GOOS=linux go build -o /pvmbg src/main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /pvmbg .
EXPOSE 8082
CMD ["./pvmbg"]
