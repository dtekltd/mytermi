# MyTermi server. `make build` = console (Next.js static export) + Go binary.
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
BIN     ?= bin/mytermi
DIST    := internal/console/dist

.PHONY: build console server test run dev-db clean

build: console server

console:
	cd console && npm ci --no-audit --no-fund && npm run build
	find $(DIST) -mindepth 1 ! -name .gitkeep -delete
	cp -R console/out/. $(DIST)/

server:
	CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$(VERSION)" -o $(BIN) ./cmd/mytermi

# Integration tests need a throwaway Postgres (see `make dev-db`).
test:
	MYTERMI_TEST_DATABASE_URL=$${MYTERMI_TEST_DATABASE_URL:-postgres://postgres:mytermi@127.0.0.1:5432/mytermi_test?sslmode=disable} \
		go test -p 1 ./...

# Postgres for development on localhost:5432 (databases mytermi + mytermi_test).
dev-db:
	docker compose -f ../docker-compose.yml up -d db

run: server
	MYTERMI_DATABASE_URL=$${MYTERMI_DATABASE_URL:-postgres://postgres:mytermi@127.0.0.1:5432/mytermi?sslmode=disable} \
	MYTERMI_DEV=1 ./$(BIN) serve

clean:
	rm -rf bin console/out console/.next
	find $(DIST) -mindepth 1 ! -name .gitkeep -delete
