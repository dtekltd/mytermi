# Build: docker build -t mytermi-server server/
FROM node:22-alpine AS console
WORKDIR /src/console
COPY console/package.json console/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY console/ ./
RUN npm run build

FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=console /src/console/out/ ./internal/console/dist/
ARG VERSION=docker
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/mytermi ./cmd/mytermi

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/mytermi /mytermi
EXPOSE 8080
USER nonroot
ENTRYPOINT ["/mytermi"]
CMD ["serve"]
