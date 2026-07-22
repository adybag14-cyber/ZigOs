SHELL := /bin/sh

.PHONY: build assets test check clean

build:
	./scripts/build.sh

assets:
	./scripts/build.sh assets

test:
	./scripts/build.sh test

check:
	./scripts/build.sh check

clean:
	rm -rf .zig-cache zig-out build src/generated
