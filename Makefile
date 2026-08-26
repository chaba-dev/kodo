.PHONY: dev
dev:
	mix phx.server

.PHONY: dev-console
dev-console:
	iex -S mix phx.server

.PHONY: dev-agent
dev-agent:
	cargo run -p kodo -- daemon --workspace . --control-plane http://127.0.0.1:4451

.PHONY: test
test: ex-test rs-test

.PHONY: ex-test
ex-test:
	mix test

.PHONY: rs-test
rs-test:
	cargo test --workspace

.PHONY: lint
lint: ex-lint rs-lint

.PHONY: ex-lint
ex-lint:
	mix credo

.PHONY: rs-lint
rs-lint:
	cargo clippy --workspace --all-features -- -D warnings

.PHONY: rs-fmt
rs-fmt:
	cargo fmt --check

.PHONY: up
up:
	docker compose up -d

.PHONY: down
down:
	docker compose stop

.PHONY: migrate
migrate:
	mix ecto.migration

.PHONY: db
db:
	psql -h 127.0.0.1 -U postgres -d kodo_dev -p 5435 -W

.PHONY: console
console:
	iex -S mix

.PHONY: changelog
changelog:
	git cliff --output CHANGELOG.md
