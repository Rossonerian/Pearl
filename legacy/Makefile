# Pearl — Liquid Glass Native AI Companion for MacBook Neo
# Makefile for building native binaries and installing

PREFIX ?= $(HOME)/.local
BIN_DIR ?= $(PREFIX)/bin
PEARL_DIR ?= $(HOME)/.pearl
LIB_DIR ?= $(PREFIX)/lib/pearl
PYTHON_TTS ?= /opt/homebrew/bin/python3.11
TTS_VENV ?= $(HOME)/.local/share/pearl/tts_env311

CC = clang
SWIFTC = swiftc
CFLAGS = -O3 -Wall
SWIFTFLAGS = -O -framework AppKit -framework AVFoundation

all: guard hud

guard: bin/pearl-guard

bin/pearl-guard: src/guard/pearl-guard.c
	@mkdir -p bin
	$(CC) $(CFLAGS) src/guard/pearl-guard.c -o bin/pearl-guard
	@chmod +x bin/pearl-guard
	@echo "Built bin/pearl-guard"

hud: bin/pearl-hud

bin/pearl-hud: src/hud/PearlHUD.swift
	@mkdir -p bin
	$(SWIFTC) $(SWIFTFLAGS) src/hud/PearlHUD.swift -o bin/pearl-hud
	@chmod +x bin/pearl-hud
	@echo "Built bin/pearl-hud"

install: all
	@mkdir -p $(BIN_DIR) $(PEARL_DIR) $(LIB_DIR)
	cp bin/pearl $(BIN_DIR)/pearl
	cp bin/pearl-server $(BIN_DIR)/pearl-server
	cp bin/pearl-telemetry $(BIN_DIR)/pearl-telemetry
	cp bin/pearl-speak $(BIN_DIR)/pearl-speak
	cp bin/pearl-personality $(BIN_DIR)/pearl-personality
	cp bin/pearl-brief $(BIN_DIR)/pearl-brief
	cp bin/pearl-battery $(BIN_DIR)/pearl-battery
	cp bin/pearl-note $(BIN_DIR)/pearl-note
	cp bin/pearl-guard $(BIN_DIR)/pearl-guard
	cp bin/pearl-hud $(BIN_DIR)/pearl-hud
	cp bin/pearl-tts $(BIN_DIR)/pearl-tts
	cp bin/pearl-tts-engine $(BIN_DIR)/pearl-tts-engine
	@chmod +x $(BIN_DIR)/pearl*
	@rm -rf $(LIB_DIR)/pearl_tts
	@cp -R src/tts/pearl_tts $(LIB_DIR)/pearl_tts
	@if [ ! -f $(PEARL_DIR)/tts.json ]; then \
		cp config/tts.json $(PEARL_DIR)/tts.json; \
	fi
	@if [ ! -f $(PEARL_DIR)/PERSONALITY_STATE.json ]; then \
		cp state_template/PERSONALITY_STATE.json $(PEARL_DIR)/; \
	fi
	@if [ ! -f $(PEARL_DIR)/USER_PROFILE.md ]; then \
		cp state_template/USER_PROFILE.md $(PEARL_DIR)/; \
	fi
	@if [ ! -f $(PEARL_DIR)/diary.md ]; then \
		cp state_template/diary.md $(PEARL_DIR)/; \
	fi
	@echo "Pearl installed successfully to $(BIN_DIR)"
	@echo "Streaming TTS: run 'make tts-setup && make tts-models' once, then 'pearl-tts --bench'"

# Optional local neural speech stack (Python 3.11/3.12; ONNX wheels are not
# yet published for 3.13+ on macOS ARM).
tts-setup:
	@test -x $(PYTHON_TTS) || (echo "Need Python 3.11/3.12 at $(PYTHON_TTS)"; exit 1)
	$(PYTHON_TTS) -m venv $(TTS_VENV)
	$(TTS_VENV)/bin/pip install --upgrade pip
	$(TTS_VENV)/bin/pip install kokoro-onnx sounddevice numpy
	@echo "TTS environment ready at $(TTS_VENV)"

tts-models:
	./tools/fetch_tts_models.sh

test-tts:
	cd src/tts && PYTHONPATH=. $(PYTHON_TTS) -m unittest discover -s tests -v

bench-tts:
	./bin/pearl-tts --bench --cold

clean:
	rm -f bin/pearl-guard bin/pearl-hud
	find src/tts -name __pycache__ -type d -prune -exec rm -rf {} +
	@echo "Cleaned build artifacts"

.PHONY: all guard hud install clean tts-setup tts-models test-tts bench-tts
