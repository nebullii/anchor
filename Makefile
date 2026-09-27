# Shortcuts for common Anchor dev tasks. Each target is a thin wrapper, so
# the underlying commands in bin/ and docker-compose.yml stay the source of truth.

.PHONY: setup dev test lint security ci up down reset

setup:      ## Install gems, create .env + database, seed the demo project
	bin/setup --skip-server

dev:        ## Run web + worker + CSS watcher (http://localhost:3000)
	bin/dev

test:       ## Run the full RSpec suite
	bundle exec rspec

lint:       ## RuboCop
	bundle exec rubocop

security:   ## Brakeman + bundler-audit
	bundle exec brakeman --no-pager -q -w3
	command -v bundle-audit > /dev/null || gem install bundler-audit --no-document
	bundle-audit check --update

ci: lint security test  ## Everything CI runs for the Rails app

up:         ## Full stack in containers (no local Ruby/Postgres/Redis needed)
	docker compose up --build

down:       ## Stop containers (add -v yourself to wipe the database volume)
	docker compose down

reset:      ## Drop, recreate and reseed the development database
	bin/setup --skip-server --reset
