# Pearl — Liquid Glass Native AI Companion for MacBook Neo
# Makefile for building native binaries and installing

PREFIX ?= $(HOME)/.local
BIN_DIR ?= $(PREFIX)/bin
PEARL_DIR ?= $(HOME)/.pearl

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
	@mkdir -p $(BIN_DIR) $(PEARL_DIR)
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
	@chmod +x $(BIN_DIR)/pearl*
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

clean:
	rm -f bin/pearl-guard bin/pearl-hud
	@echo "Cleaned build artifacts"

.PHONY: all guard hud install clean
