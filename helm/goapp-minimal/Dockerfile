FROM golang:latest AS builder

WORKDIR /app
COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o webserver

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /app/webserver .


EXPOSE 8080
ENTRYPOINT ["./webserver"]
