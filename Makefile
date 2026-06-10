.PHONY: lint desktop-start desktop-stop

lint:
	shellcheck scripts/*.sh

desktop-start:
	./scripts/start-desktop.sh

desktop-stop:
	./scripts/stop-desktop.sh
