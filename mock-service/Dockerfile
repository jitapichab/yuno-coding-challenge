# Stage 1: Build
FROM golang:1.23.4-alpine3.21 AS builder

WORKDIR /app

# Copy dependency files first for layer caching.
COPY go.mod go.sum ./
RUN go mod download

# Copy source code.
COPY . .

# Build static binary.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /app/mock-service .

# Stage 2: Runtime (distroless, non-root)
FROM gcr.io/distroless/static-debian12:nonroot

# Copy the binary from the builder stage.
COPY --from=builder /app/mock-service /mock-service

# Run as non-root user (uid 65534 = nobody).
USER 65534:65534

EXPOSE 8080

ENTRYPOINT ["/mock-service"]
