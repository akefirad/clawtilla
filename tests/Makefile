# Clawtilla verification — convenience targets. Thin wrapper over ./run.sh.

SHELL := /bin/bash

.PHONY: all static build runtime verify list manual down clean clean-logs help

all: ## run the full suite (static + build + runtime)
	bash run.sh

static: ## static checks only (no docker run)
	bash run.sh static

build: ## build both images
	bash run.sh build

runtime: ## runtime checks (assumes images built; brings the stack up)
	bash run.sh runtime

verify: ## build + runtime (skip static)
	bash run.sh build runtime

manual: ## runtime with human enrollment approval
	bash run.sh --manual-approve runtime

down: ## tear the verification stack down (volumes too) — scoped + ownership-guarded
	bash run.sh --teardown

list: ## list all test scripts
	bash run.sh --list

clean: ## remove session/scratch files (KEEPS per-run logs)
	rm -f logs/.results.tsv logs/.cp_session.cookies logs/.dash_port

clean-logs: ## delete ALL retained per-run logs + ledgers (destructive)
	rm -f logs/verify-*.log logs/results-*.tsv logs/build-*.log

help: ## show targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'
