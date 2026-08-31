# llm-ctl
PREFIX ?= $(HOME)/.local
SHELL  := bash

SOURCES := bin/llm-ctl lib/*.sh backends/*.sh tests/run.sh tests/stubs/*

.PHONY: help test lint check install uninstall

help:  ## show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk -F':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

test:  ## run the test suite (no docker, no GPU, no network needed)
	@./tests/run.sh

lint:  ## shellcheck everything
	@shellcheck -x -s bash $(SOURCES)

check: lint test  ## lint and test

install:  ## install for the current user
	@./install.sh --prefix $(PREFIX)

uninstall:  ## remove it again
	@./install.sh --prefix $(PREFIX) --uninstall
