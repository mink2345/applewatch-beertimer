FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod ./
RUN go get github.com/gorilla/websocket github.com/lib/pq
COPY . .
RUN go build -o server main.go

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /app/server .
EXPOSE 8080
CMD ["./server"]