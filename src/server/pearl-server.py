#!/usr/bin/env python3
"""
Pearl Local HTTP Bridge Server
==============================
High-performance, lightweight local HTTP bridge for Pearl, Rosso's personal AI companion.
Provides native macOS Liquid Glass Web UI and REST/SSE API for Phi Browser and local clients.

Port: 49200 (127.0.0.1)
Endpoints:
  GET  /               - Sleek Liquid Glass macOS dark-mode Web UI
  POST /api/chat       - Send prompt to Pearl CLI / Ollama {"prompt": "..."} -> {"response": "..."}
  GET  /api/chat/stream- Real-time token streaming via Server-Sent Events (SSE)
  POST /api/chat/stream- Real-time streaming via SSE with JSON body
  GET  /api/status     - System telemetry, battery, circadian mood from PERSONALITY_STATE.json
  POST /api/note       - Adds a note to ~/.pearl/scratchpad.md and ~/.pearl/timeline.md
  GET  /api/notes      - Returns scratchpad notes
  GET  /api/diary      - Returns Pearl's diary reflections
  GET  /api/brief      - Returns status briefing for MacBook Neo
"""

import sys
import os
import json
import subprocess
import re
import datetime
import urllib.parse
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

PORT = 49200
HOST = "127.0.0.1"
PEARL_BIN = "/Users/rossonerian/.local/bin/pearl"
PEARL_BRIEF_BIN = "/Users/rossonerian/.local/bin/pearl-brief"
PEARL_TELEMETRY_BIN = "/Users/rossonerian/.local/bin/pearl-telemetry"
PEARL_PERSONALITY_BIN = "/Users/rossonerian/.local/bin/pearl-personality"
STATE_FILE = os.path.expanduser("~/.pearl/PERSONALITY_STATE.json")
SCRATCHPAD_FILE = os.path.expanduser("~/.pearl/scratchpad.md")
TIMELINE_FILE = os.path.expanduser("~/.pearl/timeline.md")
DIARY_FILE = os.path.expanduser("~/.pearl/diary.md")
PROFILE_FILE = os.path.expanduser("~/.pearl/USER_PROFILE.md")
OLLAMA_URL = "http://127.0.0.1:11434"
OLLAMA_MODEL = "pearl-1.5b:latest"

START_TIME = datetime.datetime.now()

# ---------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------

def get_battery_info():
    """Extract power source, percentage, and charging state via pmset."""
    try:
        res = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=3)
        out = res.stdout.strip()
        pct_match = re.search(r"([0-9]+%)", out)
        pct = pct_match.group(1) if pct_match else "unknown"
        
        # Determine charging state carefully
        is_charging = bool(re.search(r"\bcharging\b|ac power", out, re.IGNORECASE))
        is_discharging = bool(re.search(r"\bdischarging\b", out, re.IGNORECASE))
        
        if is_charging:
            state = "charging"
        elif is_discharging:
            state = "discharging"
        else:
            state = "on battery"
            
        source = "AC Power" if "AC Power" in out else "Battery Power"
        
        # Time remaining
        remaining_match = re.search(r"(\d+:\d+)\s+remaining", out)
        remaining = remaining_match.group(1) if remaining_match else None
        
        return {
            "percentage": pct,
            "state": state,
            "is_charging": is_charging,
            "source": source,
            "remaining": remaining,
            "raw": out
        }
    except Exception as e:
        return {
            "percentage": "unknown",
            "state": "unknown",
            "is_charging": False,
            "source": "unknown",
            "error": str(e)
        }

def get_personality_state():
    """Read ~/.pearl/PERSONALITY_STATE.json."""
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            return {"error": str(e)}
    return {
        "familiarity_level": 1,
        "familiarity_title": "Companion",
        "current_mood": "morning_clarity",
        "mood_description": "Motivated and ready.",
        "traits": {"wit": 0.85, "empathy": 0.95, "candidness": 0.90, "warmth": 0.95}
    }

def get_system_telemetry():
    """Retrieve full macOS telemetry and Pearl status."""
    battery = get_battery_info()
    personality = get_personality_state()
    
    # Memory free percentage
    mem_free = "optimal"
    try:
        mp = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=3)
        mem_match = re.search(r"System-wide memory free percentage:\s*([0-9]+%)", mp.stdout)
        if mem_match:
            mem_free = mem_match.group(1)
    except Exception:
        pass
        
    # Raw pearl-telemetry output if binary is present
    telemetry_raw = ""
    if os.path.exists(PEARL_TELEMETRY_BIN) and os.access(PEARL_TELEMETRY_BIN, os.X_OK):
        try:
            t_res = subprocess.run([PEARL_TELEMETRY_BIN], capture_output=True, text=True, timeout=3)
            telemetry_raw = t_res.stdout.strip()
        except Exception:
            pass

    # Frontmost app extraction
    front_app = "Unknown"
    front_win = "None"
    try:
        osa_cmd = '''
        tell application "System Events"
            set p to first process whose frontmost is true
            set appName to name of p
            set winTitle to "Main Window"
            try
                set winTitle to name of front window of p
            end try
            return appName & "|||" & winTitle
        end tell
        '''
        osa = subprocess.run(["osascript", "-e", osa_cmd], capture_output=True, text=True, timeout=2)
        if osa.returncode == 0 and "|||" in osa.stdout:
            parts = osa.stdout.strip().split("|||", 1)
            front_app = parts[0]
            front_win = parts[1]
    except Exception:
        pass

    # Notes count
    notes_count = len(get_notes().get("notes", []))
    
    now = datetime.datetime.now()
    hour = now.hour
    if 5 <= hour < 12:
        phase = "Morning"
    elif 12 <= hour < 18:
        phase = "Afternoon"
    elif 18 <= hour < 23:
        phase = "Evening"
    else:
        phase = "Late Night"

    uptime_sec = int((datetime.datetime.now() - START_TIME).total_seconds())

    return {
        "status": "online",
        "server": "pearl-bridge/1.0",
        "machine": "MacBook Neo",
        "timestamp": now.isoformat(),
        "phase": phase,
        "day": now.strftime("%A"),
        "time": now.strftime("%I:%M %p"),
        "uptime_seconds": uptime_sec,
        "battery": battery,
        "memory_free": mem_free,
        "frontmost_app": front_app,
        "frontmost_window": front_win,
        "active_notes_count": notes_count,
        "personality": personality,
        "circadian_mood": personality.get("current_mood", "morning_clarity"),
        "mood_description": personality.get("mood_description", ""),
        "familiarity_title": personality.get("familiarity_title", "Trusted Partner"),
        "telemetry_raw": telemetry_raw
    }

def get_notes():
    """Read and parse notes from ~/.pearl/scratchpad.md."""
    notes = []
    raw = ""
    if os.path.exists(SCRATCHPAD_FILE):
        try:
            with open(SCRATCHPAD_FILE, "r", encoding="utf-8") as f:
                raw = f.read()
                for line in raw.splitlines():
                    s = line.strip()
                    if not s:
                        continue
                    m = re.match(r"^-\s*\[(.*?)\]\s*(.*)$", s)
                    if m:
                        notes.append({"timestamp": m.group(1), "content": m.group(2)})
                    elif s.startswith("- "):
                        notes.append({"timestamp": "", "content": s[2:].strip()})
        except Exception:
            pass
    return {"count": len(notes), "notes": notes, "raw": raw}

def add_note_text(text):
    """Append a note to scratchpad.md and timeline.md."""
    text = text.strip()
    if not text:
        return {"success": False, "error": "Note text cannot be empty"}
        
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    note_line = f"- [{now_str}] {text}\n"
    timeline_line = f"- [{now_str}] Note recorded: {text}\n"
    
    os.makedirs(os.path.dirname(SCRATCHPAD_FILE), exist_ok=True)
    
    with open(SCRATCHPAD_FILE, "a", encoding="utf-8") as f:
        f.write(note_line)
        
    with open(TIMELINE_FILE, "a", encoding="utf-8") as f:
        f.write(timeline_line)
        
    all_notes = get_notes()
    return {
        "success": True,
        "note": text,
        "timestamp": now_str,
        "total_notes": all_notes["count"],
        "message": f"I've noted that down for you: \"{text}\""
    }

def get_diary():
    """Read and parse reflections from ~/.pearl/diary.md."""
    raw = ""
    entries = []
    latest = ""
    if os.path.exists(DIARY_FILE):
        try:
            with open(DIARY_FILE, "r", encoding="utf-8") as f:
                raw = f.read()
            curr_title = ""
            curr_body = []
            for line in raw.splitlines():
                if line.startswith("## "):
                    if curr_title or curr_body:
                        entries.append({"title": curr_title, "content": "\n".join(curr_body).strip()})
                    curr_title = line[3:].strip()
                    curr_body = []
                elif line.startswith("# "):
                    continue
                else:
                    if curr_title:
                        curr_body.append(line)
            if curr_title or curr_body:
                entries.append({"title": curr_title, "content": "\n".join(curr_body).strip()})
            if entries:
                latest = entries[-1]["content"]
        except Exception:
            pass
    return {"count": len(entries), "entries": entries, "latest": latest, "raw": raw}

def get_briefing():
    """Execute pearl-brief binary or fallback to generated briefing."""
    if os.path.exists(PEARL_BRIEF_BIN) and os.access(PEARL_BRIEF_BIN, os.X_OK):
        try:
            res = subprocess.run([PEARL_BRIEF_BIN], capture_output=True, text=True, timeout=5)
            if res.returncode == 0 and res.stdout.strip():
                return res.stdout.strip()
        except Exception:
            pass
            
    # Fallback briefing
    now = datetime.datetime.now()
    batt = get_battery_info()
    notes = get_notes()
    return (
        f"Good day, Rosso. It's {now.strftime('%A, %B %d, at %I:%M %p')}.\n"
        f"MacBook Neo is at {batt['percentage']} ({batt['state']}).\n"
        f"You have {notes['count']} active note(s) in your scratchpad."
    )

def execute_pearl_cli(prompt):
    """Execute /Users/rossonerian/.local/bin/pearl -q '<prompt>'."""
    env = os.environ.copy()
    env["PATH"] = f"/Users/rossonerian/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:{env.get('PATH', '')}"
    try:
        res = subprocess.run(
            [PEARL_BIN, "-q", prompt],
            capture_output=True,
            text=True,
            timeout=45,
            env=env
        )
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
        if res.stderr:
            sys.stderr.write(f"[pearl-server] pearl stderr: {res.stderr}\n")
    except subprocess.TimeoutExpired:
        sys.stderr.write("[pearl-server] pearl -q timed out after 45s\n")
    except Exception as e:
        sys.stderr.write(f"[pearl-server] pearl invocation error: {e}\n")
        
    # Fallback directly to Ollama if pearl CLI is unavailable or fails
    return fallback_ollama_generate(prompt)

def fallback_ollama_generate(prompt):
    """Direct fallback to Ollama pearl-1.5b:latest."""
    try:
        url = f"{OLLAMA_URL}/api/generate"
        payload = json.dumps({
            "model": OLLAMA_MODEL,
            "prompt": prompt,
            "stream": False
        }).encode("utf-8")
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("response", "I'm right here with you on MacBook Neo, Rosso.")
    except Exception as e:
        return f"Pearl is standing by on MacBook Neo. (Error connecting to model: {e})"

# ---------------------------------------------------------
# Embedded Native macOS Liquid Glass Web UI
# ---------------------------------------------------------

HTML_UI = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
    <title>Pearl — AI Companion for MacBook Neo</title>
    <style>
        :root {
            --bg: #07090e;
            --surface: rgba(18, 22, 34, 0.65);
            --surface-hover: rgba(28, 34, 52, 0.75);
            --surface-border: rgba(255, 255, 255, 0.08);
            --surface-highlight: rgba(255, 255, 255, 0.12);
            --text-primary: #f8fafc;
            --text-secondary: #94a3b8;
            --text-muted: #64748b;
            --accent-cyan: #38bdf8;
            --accent-purple: #c084fc;
            --accent-pink: #f472b6;
            --accent-emerald: #34d399;
            --accent-amber: #fbbf24;
            --glass-blur: blur(28px) saturate(180%);
            --font-stack: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "Helvetica Neue", sans-serif;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
            -webkit-font-smoothing: antialiased;
        }

        body {
            font-family: var(--font-stack);
            background-color: var(--bg);
            color: var(--text-primary);
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            overflow-x: hidden;
            background-image: 
                radial-gradient(circle at 10% 10%, rgba(56, 189, 248, 0.08) 0%, transparent 45%),
                radial-gradient(circle at 90% 20%, rgba(192, 132, 252, 0.07) 0%, transparent 40%),
                radial-gradient(circle at 50% 90%, rgba(52, 211, 153, 0.05) 0%, transparent 50%);
            background-attachment: fixed;
        }

        /* Glass Shell Layout */
        .app-container {
            max-width: 1040px;
            width: 100%;
            margin: 0 auto;
            display: flex;
            flex-direction: column;
            flex: 1;
            padding: 20px 24px;
            gap: 16px;
        }

        /* Header Bar */
        header.liquid-nav {
            display: flex;
            align-items: center;
            justify-content: space-between;
            background: var(--surface);
            backdrop-filter: var(--glass-blur);
            -webkit-backdrop-filter: var(--glass-blur);
            border: 1px solid var(--surface-border);
            border-radius: 20px;
            padding: 12px 20px;
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.4), inset 0 1px 0 var(--surface-highlight);
            position: sticky;
            top: 16px;
            z-index: 100;
        }

        .brand-section {
            display: flex;
            align-items: center;
            gap: 14px;
        }

        .pearl-avatar {
            width: 38px;
            height: 38px;
            border-radius: 50%;
            background: linear-gradient(135deg, #38bdf8 0%, #c084fc 50%, #f472b6 100%);
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 0 18px rgba(192, 132, 252, 0.45);
            position: relative;
        }

        .pearl-avatar::after {
            content: '';
            position: absolute;
            width: 10px;
            height: 10px;
            background: #fff;
            border-radius: 50%;
            box-shadow: 0 0 8px #fff;
        }

        .brand-info h1 {
            font-size: 17px;
            font-weight: 600;
            letter-spacing: -0.02em;
            background: linear-gradient(180deg, #ffffff 30%, #cbd5e1 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .brand-info p {
            font-size: 12px;
            color: var(--text-muted);
            letter-spacing: -0.01em;
        }

        .status-indicators {
            display: flex;
            align-items: center;
            gap: 10px;
            flex-wrap: wrap;
        }

        .glass-pill {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 30px;
            padding: 5px 12px;
            font-size: 12px;
            font-weight: 500;
            color: var(--text-secondary);
            backdrop-filter: blur(12px);
            transition: all 0.2s ease;
        }

        .glass-pill:hover {
            background: rgba(255, 255, 255, 0.09);
            border-color: rgba(255, 255, 255, 0.16);
        }

        .pulsing-dot {
            width: 7px;
            height: 7px;
            border-radius: 50%;
            background: var(--accent-emerald);
            box-shadow: 0 0 8px var(--accent-emerald);
            animation: pulse-glow 2.4s infinite ease-in-out;
        }

        @keyframes pulse-glow {
            0%, 100% { opacity: 0.6; transform: scale(0.95); }
            50% { opacity: 1; transform: scale(1.25); }
        }

        /* Quick Action Bar */
        .quick-actions {
            display: flex;
            gap: 8px;
            overflow-x: auto;
            padding: 2px 0 6px 0;
            scrollbar-width: none;
        }
        .quick-actions::-webkit-scrollbar { display: none; }

        .action-chip {
            background: var(--surface);
            backdrop-filter: var(--glass-blur);
            border: 1px solid var(--surface-border);
            border-radius: 14px;
            padding: 8px 14px;
            font-size: 13px;
            font-weight: 500;
            color: var(--text-secondary);
            cursor: pointer;
            display: flex;
            align-items: center;
            gap: 7px;
            transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1);
            white-space: nowrap;
        }

        .action-chip:hover {
            background: var(--surface-hover);
            color: var(--text-primary);
            border-color: rgba(255, 255, 255, 0.18);
            transform: translateY(-1px);
        }

        .action-chip:active {
            transform: translateY(1px);
        }

        .action-chip svg {
            width: 14px;
            height: 14px;
            opacity: 0.85;
        }

        /* Chat Window */
        .chat-container {
            flex: 1;
            background: var(--surface);
            backdrop-filter: var(--glass-blur);
            -webkit-backdrop-filter: var(--glass-blur);
            border: 1px solid var(--surface-border);
            border-radius: 24px;
            padding: 24px;
            display: flex;
            flex-direction: column;
            gap: 20px;
            overflow-y: auto;
            min-height: 480px;
            max-height: calc(100vh - 290px);
            box-shadow: 0 20px 50px rgba(0, 0, 0, 0.45), inset 0 1px 0 var(--surface-highlight);
        }

        /* Welcome Card */
        .welcome-card {
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid rgba(255, 255, 255, 0.06);
            border-radius: 18px;
            padding: 20px;
            display: flex;
            flex-direction: column;
            gap: 12px;
            border-left: 3px solid var(--accent-purple);
        }

        .welcome-card h2 {
            font-size: 16px;
            font-weight: 600;
            color: #fff;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .welcome-card p {
            font-size: 13.5px;
            color: var(--text-secondary);
            line-height: 1.5;
        }

        .welcome-card .quote {
            font-style: italic;
            color: var(--accent-cyan);
            font-size: 12.5px;
            border-left: 2px solid rgba(56, 189, 248, 0.4);
            padding-left: 10px;
            margin-top: 4px;
        }

        /* Message Bubbles */
        .message-row {
            display: flex;
            width: 100%;
            gap: 12px;
            animation: fadeIn 0.25s ease-out;
        }

        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(6px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .message-row.user {
            justify-content: flex-end;
        }

        .message-bubble {
            max-width: 80%;
            padding: 12px 18px;
            border-radius: 18px;
            font-size: 14px;
            line-height: 1.55;
            word-break: break-word;
            position: relative;
        }

        .message-row.user .message-bubble {
            background: linear-gradient(135deg, rgba(56, 189, 248, 0.25) 0%, rgba(192, 132, 252, 0.25) 100%);
            border: 1px solid rgba(255, 255, 255, 0.15);
            color: #fff;
            border-bottom-right-radius: 4px;
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.25);
        }

        .message-row.pearl .message-bubble {
            background: rgba(255, 255, 255, 0.045);
            border: 1px solid rgba(255, 255, 255, 0.08);
            color: #f1f5f9;
            border-bottom-left-radius: 4px;
            box-shadow: 0 6px 24px rgba(0, 0, 0, 0.35);
        }

        .pearl-msg-header {
            display: flex;
            align-items: center;
            gap: 6px;
            margin-bottom: 6px;
            font-size: 11.5px;
            font-weight: 600;
            color: var(--accent-purple);
            text-transform: uppercase;
            letter-spacing: 0.04em;
        }

        .message-bubble pre {
            background: rgba(0, 0, 0, 0.4);
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 10px;
            padding: 10px 14px;
            margin: 8px 0;
            overflow-x: auto;
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            font-size: 12.5px;
        }

        .message-bubble code {
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            background: rgba(255, 255, 255, 0.08);
            padding: 2px 5px;
            border-radius: 4px;
            font-size: 12.5px;
        }

        /* Waveform HUD Animation */
        .hud-waveform {
            display: inline-flex;
            align-items: center;
            gap: 3px;
            height: 14px;
            margin-left: 6px;
            vertical-align: middle;
        }

        .hud-bar {
            width: 3px;
            height: 100%;
            background: var(--accent-cyan);
            border-radius: 2px;
            animation: hud-bounce 1s infinite ease-in-out;
        }
        .hud-bar:nth-child(2) { animation-delay: 0.15s; background: var(--accent-purple); }
        .hud-bar:nth-child(3) { animation-delay: 0.3s; background: var(--accent-pink); }
        .hud-bar:nth-child(4) { animation-delay: 0.45s; background: var(--accent-cyan); }

        @keyframes hud-bounce {
            0%, 100% { height: 4px; opacity: 0.4; }
            50% { height: 14px; opacity: 1; }
        }

        /* Streaming Caret */
        .cursor-blink {
            display: inline-block;
            width: 7px;
            height: 14px;
            background: var(--accent-cyan);
            margin-left: 2px;
            vertical-align: -2px;
            border-radius: 1px;
            animation: blink 0.9s infinite;
        }

        @keyframes blink {
            0%, 100% { opacity: 0; }
            50% { opacity: 1; }
        }

        /* Bottom Floating Input Dock */
        .input-dock {
            background: var(--surface);
            backdrop-filter: var(--glass-blur);
            -webkit-backdrop-filter: var(--glass-blur);
            border: 1px solid var(--surface-border);
            border-radius: 20px;
            padding: 10px 14px;
            display: flex;
            align-items: flex-end;
            gap: 10px;
            box-shadow: 0 16px 40px rgba(0, 0, 0, 0.5), inset 0 1px 0 var(--surface-highlight);
            position: relative;
        }

        .chat-input {
            flex: 1;
            background: transparent;
            border: none;
            outline: none;
            color: #fff;
            font-family: var(--font-stack);
            font-size: 14px;
            line-height: 1.45;
            resize: none;
            max-height: 120px;
            min-height: 24px;
            padding: 4px 6px;
        }

        .chat-input::placeholder {
            color: var(--text-muted);
        }

        .dock-actions {
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .send-btn {
            width: 36px;
            height: 36px;
            border-radius: 50%;
            background: linear-gradient(135deg, #38bdf8 0%, #c084fc 100%);
            border: none;
            color: #fff;
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: all 0.2s cubic-bezier(0.16, 1, 0.3, 1);
            box-shadow: 0 4px 14px rgba(56, 189, 248, 0.35);
        }

        .send-btn:hover {
            transform: scale(1.05);
            box-shadow: 0 6px 20px rgba(192, 132, 252, 0.5);
        }

        .send-btn:disabled {
            opacity: 0.4;
            cursor: not-allowed;
            transform: none;
        }

        .send-btn svg {
            width: 16px;
            height: 16px;
        }

        .footer-hints {
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 11.5px;
            color: var(--text-muted);
            padding: 0 6px;
        }

        /* Slide-over Drawer / Modal */
        .drawer-overlay {
            position: fixed;
            inset: 0;
            background: rgba(0, 0, 0, 0.65);
            backdrop-filter: blur(8px);
            z-index: 200;
            display: none;
            align-items: center;
            justify-content: center;
            opacity: 0;
            transition: opacity 0.25s ease;
        }

        .drawer-overlay.active {
            display: flex;
            opacity: 1;
        }

        .drawer-card {
            background: rgba(22, 27, 44, 0.85);
            backdrop-filter: var(--glass-blur);
            border: 1px solid var(--surface-border);
            border-radius: 24px;
            width: 90%;
            max-width: 580px;
            max-height: 80vh;
            display: flex;
            flex-direction: column;
            box-shadow: 0 25px 60px rgba(0, 0, 0, 0.6), inset 0 1px 0 var(--surface-highlight);
            overflow: hidden;
            animation: zoomIn 0.2s ease-out;
        }

        @keyframes zoomIn {
            from { transform: scale(0.96); opacity: 0; }
            to { transform: scale(1); opacity: 1; }
        }

        .drawer-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 18px 24px;
            border-bottom: 1px solid var(--surface-border);
        }

        .drawer-header h3 {
            font-size: 16px;
            font-weight: 600;
            color: #fff;
        }

        .close-btn {
            background: rgba(255, 255, 255, 0.08);
            border: none;
            color: var(--text-secondary);
            border-radius: 50%;
            width: 28px;
            height: 28px;
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: all 0.2s;
        }

        .close-btn:hover {
            background: rgba(255, 255, 255, 0.16);
            color: #fff;
        }

        .drawer-body {
            padding: 20px 24px;
            overflow-y: auto;
            display: flex;
            flex-direction: column;
            gap: 14px;
        }

        .note-item {
            background: rgba(255, 255, 255, 0.035);
            border: 1px solid rgba(255, 255, 255, 0.07);
            border-radius: 12px;
            padding: 12px 16px;
        }

        .note-item .time {
            font-size: 11px;
            color: var(--accent-cyan);
            margin-bottom: 4px;
            font-weight: 500;
        }

        .note-item .text {
            font-size: 13.5px;
            color: var(--text-primary);
            line-height: 1.45;
        }

        .note-input-box {
            display: flex;
            gap: 10px;
            margin-top: 8px;
        }

        .note-input-box input {
            flex: 1;
            background: rgba(255, 255, 255, 0.06);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 12px;
            padding: 10px 14px;
            color: #fff;
            font-size: 13.5px;
            outline: none;
        }

        .note-input-box button {
            background: linear-gradient(135deg, var(--accent-cyan), var(--accent-purple));
            border: none;
            color: #fff;
            border-radius: 12px;
            padding: 0 16px;
            font-weight: 600;
            font-size: 13px;
            cursor: pointer;
        }
    </style>
</head>
<body>

    <div class="app-container">
        <!-- Liquid Glass Navigation -->
        <header class="liquid-nav">
            <div class="brand-section">
                <div class="pearl-avatar"></div>
                <div class="brand-info">
                    <h1>Pearl</h1>
                    <p>Rosso's AI Companion • MacBook Neo</p>
                </div>
            </div>

            <div class="status-indicators">
                <div class="glass-pill" id="pill-mood" title="Circadian Emotional State">
                    <span class="pulsing-dot"></span>
                    <span id="text-mood">morning_clarity</span>
                </div>
                <div class="glass-pill" id="pill-battery" title="Hardware Power Telemetry">
                    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                        <rect x="2" y="7" width="16" height="10" rx="2" ry="2"></rect>
                        <line x1="22" y1="11" x2="22" y2="13"></line>
                    </svg>
                    <span id="text-battery">55%</span>
                </div>
                <div class="glass-pill" id="pill-partner" title="Bond & Interactions">
                    <span>✨</span>
                    <span id="text-partner">Trusted Partner</span>
                </div>
            </div>
        </header>

        <!-- Quick Action Pills -->
        <div class="quick-actions">
            <button class="action-chip" onclick="triggerBriefing()">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon></svg>
                Status Briefing
            </button>
            <button class="action-chip" onclick="openScratchpad()">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"></path><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"></path></svg>
                Scratchpad Note (<span id="chip-notes-count">0</span>)
            </button>
            <button class="action-chip" onclick="openDiary()">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"></path><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"></path></svg>
                Pearl Diary
            </button>
            <button class="action-chip" onclick="sendPrompt('MacBook Neo battery status')">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="7" width="16" height="10" rx="2" ry="2"></rect><line x1="22" y1="11" x2="22" y2="13"></line></svg>
                Battery Telemetry
            </button>
            <button class="action-chip" onclick="openTelemetryModal()">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg>
                Telemetry HUD
            </button>
            <button class="action-chip" onclick="clearChat()">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg>
                Clear Chat
            </button>
        </div>

        <!-- Live Chat Container -->
        <main class="chat-container" id="chat-stream">
            <div class="welcome-card" id="welcome-card">
                <h2>
                    <span>Good morning, Rosso</span>
                    <span class="hud-waveform"><span class="hud-bar"></span><span class="hud-bar"></span><span class="hud-bar"></span><span class="hud-bar"></span></span>
                </h2>
                <p>I'm Pearl — your personal companion living right here on MacBook Neo. I keep your workflow seamless, remember your ideas, and watch over this machine.</p>
                <div class="quote" id="welcome-quote">"Rosso switched my primary mode to pure silent text on MacBook Neo. Removing all voice control and audio playback for a fast, quiet terminal workflow."</div>
            </div>
        </main>

        <!-- Bottom Input Dock -->
        <footer class="input-dock">
            <textarea 
                class="chat-input" 
                id="user-input" 
                placeholder="Talk to Pearl, remember a preference, or record a thought..." 
                rows="1"
            ></textarea>
            <div class="dock-actions">
                <button class="send-btn" id="send-btn" onclick="handleSend()" title="Send Message">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                        <line x1="12" y1="19" x2="12" y2="5"></line>
                        <polyline points="5 12 12 5 19 12"></polyline>
                    </svg>
                </button>
            </div>
        </footer>

        <div class="footer-hints">
            <span>Bridge Port: 49200 (127.0.0.1) • Streaming Enabled</span>
            <span>Return to send • Shift+Return for newline</span>
        </div>
    </div>

    <!-- Scratchpad Drawer Modal -->
    <div class="drawer-overlay" id="scratchpad-modal">
        <div class="drawer-card">
            <div class="drawer-header">
                <h3>Personal Scratchpad</h3>
                <button class="close-btn" onclick="closeModals()">✕</button>
            </div>
            <div class="drawer-body">
                <div id="notes-list" style="display:flex; flex-direction:column; gap:10px;"></div>
                <div class="note-input-box">
                    <input type="text" id="new-note-text" placeholder="Quick thought to remember...">
                    <button onclick="submitNewNote()">Add Note</button>
                </div>
            </div>
        </div>
    </div>

    <!-- Diary Modal -->
    <div class="drawer-overlay" id="diary-modal">
        <div class="drawer-card">
            <div class="drawer-header">
                <h3>Pearl's Private Diary</h3>
                <button class="close-btn" onclick="closeModals()">✕</button>
            </div>
            <div class="drawer-body" id="diary-entries-list"></div>
        </div>
    </div>

    <!-- Telemetry Modal -->
    <div class="drawer-overlay" id="telemetry-modal">
        <div class="drawer-card">
            <div class="drawer-header">
                <h3>MacBook Neo & Pearl Telemetry</h3>
                <button class="close-btn" onclick="closeModals()">✕</button>
            </div>
            <div class="drawer-body" id="telemetry-content"></div>
        </div>
    </div>

    <script>
        const chatContainer = document.getElementById('chat-stream');
        const userInput = document.getElementById('user-input');
        const sendBtn = document.getElementById('send-btn');

        // Auto-resize input textarea
        userInput.addEventListener('input', () => {
            userInput.style.height = 'auto';
            userInput.style.height = Math.min(userInput.scrollHeight, 120) + 'px';
        });

        // Enter key to send
        userInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                handleSend();
            }
        });

        // Status Poller
        async function updateStatus() {
            try {
                const res = await fetch('/api/status');
                if (res.ok) {
                    const data = await res.json();
                    if (data.circadian_mood) {
                        document.getElementById('text-mood').textContent = data.circadian_mood.replace('_', ' ');
                    }
                    if (data.battery) {
                        const chargeIcon = data.battery.is_charging ? '⚡ ' : '';
                        document.getElementById('text-battery').textContent = chargeIcon + data.battery.percentage;
                    }
                    if (data.familiarity_title) {
                        document.getElementById('text-partner').textContent = data.familiarity_title;
                    }
                    if (data.personality && data.personality.current_reflection) {
                        const q = document.getElementById('welcome-quote');
                        if (q) q.textContent = '"' + data.personality.current_reflection + '"';
                    }
                    if (data.active_notes_count !== undefined) {
                        document.getElementById('chip-notes-count').textContent = data.active_notes_count;
                    }
                }
            } catch (err) {
                console.error('Error fetching status:', err);
            }
        }
        updateStatus();
        setInterval(updateStatus, 15000);

        // Append message bubble
        function appendMessage(sender, text) {
            const row = document.createElement('div');
            row.className = `message-row ${sender}`;
            
            const bubble = document.createElement('div');
            bubble.className = 'message-bubble';
            
            if (sender === 'pearl') {
                const header = document.createElement('div');
                header.className = 'pearl-msg-header';
                header.innerHTML = `<span>Pearl</span><span class="hud-waveform"><span class="hud-bar"></span><span class="hud-bar"></span></span>`;
                bubble.appendChild(header);
            }

            const body = document.createElement('div');
            body.className = 'msg-body';
            body.innerHTML = formatMarkdown(text);
            bubble.appendChild(body);

            row.appendChild(bubble);
            chatContainer.appendChild(row);
            chatContainer.scrollTop = chatContainer.scrollHeight;
            return { row, bubble, body };
        }

        // Lightweight markdown formatter
        function formatMarkdown(text) {
            if (!text) return '';
            let html = text
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/```([\s\S]*?)```/g, '<pre><code>$1</code></pre>')
                .replace(/`([^`]+)`/g, '<code>$1</code>')
                .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
                .replace(/\*([^*]+)\*/g, '<em>$1</em>')
                .replace(/\n/g, '<br>');
            return html;
        }

        // Live Chat Handler with SSE Streaming
        async function handleSend() {
            const prompt = userInput.value.trim();
            if (!prompt) return;

            userInput.value = '';
            userInput.style.height = 'auto';
            userInput.disabled = true;
            sendBtn.disabled = true;

            appendMessage('user', prompt);

            // Pearl response placeholder with streaming caret
            const { row, bubble, body } = appendMessage('pearl', '');
            const caret = document.createElement('span');
            caret.className = 'cursor-blink';
            bubble.appendChild(caret);

            let streamedText = '';

            try {
                // Connect to SSE streaming endpoint
                const url = '/api/chat/stream?prompt=' + encodeURIComponent(prompt);
                const response = await fetch(url);

                if (!response.ok) {
                    throw new Error('Streaming failed with HTTP ' + response.status);
                }

                const reader = response.body.getReader();
                const decoder = new TextDecoder();
                let buffer = '';

                while (true) {
                    const { done, value } = await reader.read();
                    if (done) break;

                    buffer += decoder.decode(value, { stream: true });
                    const lines = buffer.split('\n');
                    buffer = lines.pop(); // keep partial line

                    for (const line of lines) {
                        const trimmed = line.trim();
                        if (trimmed.startsWith('data:')) {
                            const dataStr = trimmed.slice(5).trim();
                            if (dataStr) {
                                try {
                                    const parsed = JSON.parse(dataStr);
                                    if (parsed.token) {
                                        streamedText += parsed.token;
                                        body.innerHTML = formatMarkdown(streamedText);
                                        chatContainer.scrollTop = chatContainer.scrollHeight;
                                    }
                                    if (parsed.done && parsed.response) {
                                        streamedText = parsed.response;
                                        body.innerHTML = formatMarkdown(streamedText);
                                    }
                                } catch (e) {
                                    // Raw text line fallback
                                    streamedText += dataStr;
                                    body.innerHTML = formatMarkdown(streamedText);
                                }
                            }
                        }
                    }
                }

                if (!streamedText) {
                    body.innerHTML = "I'm right here with you on MacBook Neo, Rosso.";
                }

            } catch (err) {
                console.warn('SSE stream fallback, calling POST /api/chat:', err);
                try {
                    const fallbackRes = await fetch('/api/chat', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ prompt: prompt })
                    });
                    const fallbackData = await fallbackRes.json();
                    streamedText = fallbackData.response || "I'm standing by, Rosso.";
                    body.innerHTML = formatMarkdown(streamedText);
                } catch (fallbackErr) {
                    body.innerHTML = "Connection to Pearl interrupted: " + fallbackErr.message;
                }
            } finally {
                caret.remove();
                userInput.disabled = false;
                sendBtn.disabled = false;
                userInput.focus();
                chatContainer.scrollTop = chatContainer.scrollHeight;
                updateStatus();
            }
        }

        // Quick send helper
        function sendPrompt(text) {
            userInput.value = text;
            handleSend();
        }

        // Quick Status Briefing
        async function triggerBriefing() {
            try {
                appendMessage('user', 'Status Briefing');
                const res = await fetch('/api/brief');
                const data = await res.json();
                appendMessage('pearl', data.briefing || 'MacBook Neo is running optimally.');
            } catch (e) {
                sendPrompt('give me a briefing');
            }
        }

        // Scratchpad Modal Handlers
        async function openScratchpad() {
            const modal = document.getElementById('scratchpad-modal');
            const list = document.getElementById('notes-list');
            list.innerHTML = '<div style="color:var(--text-muted); font-size:13px;">Loading notes...</div>';
            modal.classList.add('active');

            try {
                const res = await fetch('/api/notes');
                const data = await res.json();
                document.getElementById('chip-notes-count').textContent = data.count || 0;
                list.innerHTML = '';
                if (!data.notes || data.notes.length === 0) {
                    list.innerHTML = '<div style="color:var(--text-muted); font-size:13px;">Your scratchpad is clear, Rosso.</div>';
                    return;
                }
                data.notes.forEach(n => {
                    const item = document.createElement('div');
                    item.className = 'note-item';
                    item.innerHTML = `<div class="time">${n.timestamp || 'Recent'}</div><div class="text">${n.content}</div>`;
                    list.appendChild(item);
                });
            } catch (e) {
                list.innerHTML = '<div style="color:#f87171;">Failed to load notes.</div>';
            }
        }

        async function submitNewNote() {
            const input = document.getElementById('new-note-text');
            const text = input.value.trim();
            if (!text) return;

            try {
                const res = await fetch('/api/note', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ note: text })
                });
                if (res.ok) {
                    input.value = '';
                    openScratchpad();
                    updateStatus();
                }
            } catch (e) {
                alert('Could not save note: ' + e.message);
            }
        }

        // Diary Modal Handlers
        async function openDiary() {
            const modal = document.getElementById('diary-modal');
            const list = document.getElementById('diary-entries-list');
            list.innerHTML = '<div style="color:var(--text-muted); font-size:13px;">Reading diary reflections...</div>';
            modal.classList.add('active');

            try {
                const res = await fetch('/api/diary');
                const data = await res.json();
                list.innerHTML = '';
                if (!data.entries || data.entries.length === 0) {
                    list.innerHTML = '<div style="color:var(--text-muted); font-size:13px;">My diary is just beginning, Rosso.</div>';
                    return;
                }
                data.entries.slice().reverse().forEach(e => {
                    const item = document.createElement('div');
                    item.className = 'note-item';
                    item.innerHTML = `<div class="time" style="color:var(--accent-purple); font-weight:600;">${e.title}</div><div class="text">${formatMarkdown(e.content)}</div>`;
                    list.appendChild(item);
                });
            } catch (e) {
                list.innerHTML = '<div style="color:#f87171;">Failed to load diary entries.</div>';
            }
        }

        // Telemetry Inspector Modal
        async function openTelemetryModal() {
            const modal = document.getElementById('telemetry-modal');
            const container = document.getElementById('telemetry-content');
            modal.classList.add('active');
            container.innerHTML = '<div style="color:var(--text-muted); font-size:13px;">Polling telemetry...</div>';

            try {
                const res = await fetch('/api/status');
                const d = await res.json();
                const p = d.personality || {};
                const traits = p.traits || {};

                container.innerHTML = `
                    <div style="display:grid; grid-template-columns: 1fr 1fr; gap:12px;">
                        <div class="note-item">
                            <div class="time">HARDWARE POWER</div>
                            <div class="text"><strong>${d.battery.percentage}</strong> (${d.battery.state})<br><span style="font-size:12px; color:var(--text-muted);">${d.battery.source}</span></div>
                        </div>
                        <div class="note-item">
                            <div class="time">SYSTEM MEMORY</div>
                            <div class="text"><strong>${d.memory_free} free</strong><br><span style="font-size:12px; color:var(--text-muted);">${d.machine}</span></div>
                        </div>
                        <div class="note-item">
                            <div class="time">FOCUSED APP</div>
                            <div class="text"><strong>${d.frontmost_app}</strong><br><span style="font-size:12px; color:var(--text-muted);">${d.frontmost_window}</span></div>
                        </div>
                        <div class="note-item">
                            <div class="time">CIRCADIAN MOOD</div>
                            <div class="text"><strong>${d.circadian_mood}</strong><br><span style="font-size:12px; color:var(--text-muted);">${d.familiarity_title}</span></div>
                        </div>
                    </div>

                    <div style="margin-top:14px;">
                        <div style="font-size:12px; font-weight:600; color:var(--accent-cyan); margin-bottom:8px;">EMOTIONAL TRAITS</div>
                        <div style="display:flex; flex-direction:column; gap:6px;">
                            <div><span style="font-size:12px; color:var(--text-secondary);">Wit</span> <strong style="float:right; font-size:12px;">${Math.round((traits.wit || 0.85)*100)}%</strong></div>
                            <div style="background:rgba(255,255,255,0.08); height:6px; border-radius:3px; overflow:hidden;"><div style="background:var(--accent-cyan); height:100%; width:${(traits.wit || 0.85)*100}%;"></div></div>

                            <div><span style="font-size:12px; color:var(--text-secondary);">Empathy</span> <strong style="float:right; font-size:12px;">${Math.round((traits.empathy || 0.95)*100)}%</strong></div>
                            <div style="background:rgba(255,255,255,0.08); height:6px; border-radius:3px; overflow:hidden;"><div style="background:var(--accent-pink); height:100%; width:${(traits.empathy || 0.95)*100}%;"></div></div>

                            <div><span style="font-size:12px; color:var(--text-secondary);">Candidness</span> <strong style="float:right; font-size:12px;">${Math.round((traits.candidness || 0.90)*100)}%</strong></div>
                            <div style="background:rgba(255,255,255,0.08); height:6px; border-radius:3px; overflow:hidden;"><div style="background:var(--accent-purple); height:100%; width:${(traits.candidness || 0.90)*100}%;"></div></div>

                            <div><span style="font-size:12px; color:var(--text-secondary);">Warmth</span> <strong style="float:right; font-size:12px;">${Math.round((traits.warmth || 0.95)*100)}%</strong></div>
                            <div style="background:rgba(255,255,255,0.08); height:6px; border-radius:3px; overflow:hidden;"><div style="background:var(--accent-emerald); height:100%; width:${(traits.warmth || 0.95)*100}%;"></div></div>
                        </div>
                    </div>
                `;
            } catch (e) {
                container.innerHTML = '<div style="color:#f87171;">Telemetry error: ' + e.message + '</div>';
            }
        }

        function closeModals() {
            document.querySelectorAll('.drawer-overlay').forEach(el => el.classList.remove('active'));
        }

        window.onclick = function(e) {
            if (e.target.classList.contains('drawer-overlay')) {
                closeModals();
            }
        }

        function clearChat() {
            chatContainer.innerHTML = '';
            chatContainer.appendChild(document.getElementById('welcome-card') || document.createElement('div'));
        }
    </script>
</body>
</html>
"""

# ---------------------------------------------------------
# HTTP Request Handler
# ---------------------------------------------------------

class PearlRequestHandler(BaseHTTPRequestHandler):

    server_version = "PearlBridge/1.0"

    def send_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS, PUT, DELETE")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With, Accept")
        self.send_header("Access-Control-Max-Age", "86400")

    def do_OPTIONS(self):
        """Handle CORS preflight requests."""
        self.send_response(204)
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        # 1. UI Root
        if path == "/" or path == "/index.html":
            content = HTML_UI.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(content)
            return

        # 2. Status API
        if path == "/api/status":
            data = get_system_telemetry()
            body = json.dumps(data, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(body)
            return

        # 3. Notes API (GET)
        if path == "/api/notes":
            notes_data = get_notes()
            body = json.dumps(notes_data, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(body)
            return

        # 4. Diary API
        if path == "/api/diary":
            diary_data = get_diary()
            body = json.dumps(diary_data, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(body)
            return

        # 5. Briefing API
        if path == "/api/brief" or path == "/api/briefing":
            brief_text = get_briefing()
            body = json.dumps({"briefing": brief_text}, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(body)
            return

        # 6. Real-time Chat Streaming (SSE GET /api/chat/stream?prompt=...)
        if path == "/api/chat/stream":
            prompt = query.get("prompt", [""])[0].strip()
            self.handle_sse_stream(prompt)
            return

        # 404 Fallback
        self.send_response(404)
        self.send_cors_headers()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": f"Endpoint not found: {path}"}).encode("utf-8"))

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        # Read JSON body
        content_length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(content_length) if content_length > 0 else b"{}"
        
        try:
            payload = json.loads(body_bytes.decode("utf-8")) if body_bytes else {}
        except Exception:
            payload = {}

        # 1. Chat API (POST /api/chat)
        if path == "/api/chat":
            prompt = payload.get("prompt", "")
            if not prompt:
                self.send_response(400)
                self.send_cors_headers()
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing 'prompt' parameter in JSON payload"}).encode("utf-8"))
                return

            # Check if streaming was requested in POST
            if payload.get("stream", False):
                self.handle_sse_stream(prompt)
                return

            # Execute Pearl CLI
            response_text = execute_pearl_cli(prompt)
            result = {
                "response": response_text,
                "prompt": prompt,
                "timestamp": datetime.datetime.now().isoformat()
            }
            body = json.dumps(result, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(body)
            return

        # 2. Chat Streaming via POST (/api/chat/stream)
        if path == "/api/chat/stream":
            prompt = payload.get("prompt", "").strip()
            self.handle_sse_stream(prompt)
            return

        # 3. Add Note API (POST /api/note)
        if path == "/api/note":
            note_text = payload.get("note") or payload.get("text") or payload.get("content") or ""
            res = add_note_text(note_text)
            status_code = 200 if res.get("success") else 400
            body = json.dumps(res, indent=2).encode("utf-8")
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(body)
            return

        # 404 Fallback
        self.send_response(404)
        self.send_cors_headers()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": f"Endpoint not found: {path}"}).encode("utf-8"))

    def handle_sse_stream(self, prompt):
        """Stream chat tokens via Server-Sent Events (SSE)."""
        if not prompt:
            prompt = "Hello"

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("Connection", "keep-alive")
        self.send_cors_headers()
        self.end_headers()

        def send_sse(token, done=False, full=""):
            msg = json.dumps({"token": token, "done": done, "response": full})
            self.wfile.write(f"data: {msg}\n\n".encode("utf-8"))
            self.wfile.flush()

        # Check if prompt is a quick pearl built-in command
        quick_cmd_pattern = re.compile(
            r"^(brief|status|briefing|battery|batt|diary|journal|notes?|learn|who are you|introduce yourself)",
            re.IGNORECASE
        )

        if quick_cmd_pattern.search(prompt.strip()):
            # Run quick pearl command and stream words
            response = execute_pearl_cli(prompt)
            words = response.split(" ")
            for i, w in enumerate(words):
                send_sse(w + (" " if i < len(words) - 1 else ""))
            send_sse("", done=True, full=response)
            return

        # Conversation prompt: Stream directly from Ollama pearl-1.5b:latest
        accumulated = []
        try:
            url = f"{OLLAMA_URL}/api/generate"
            payload = json.dumps({
                "model": OLLAMA_MODEL,
                "prompt": prompt,
                "stream": True
            }).encode("utf-8")
            req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                for line in resp:
                    if line:
                        chunk = json.loads(line.decode("utf-8"))
                        token = chunk.get("response", "")
                        if token:
                            accumulated.append(token)
                            send_sse(token, done=False)
                        if chunk.get("done", False):
                            break
                            
            full_response = "".join(accumulated)
            send_sse("", done=True, full=full_response)
            
            # Tick personality in background
            if os.path.exists(PEARL_PERSONALITY_BIN) and os.access(PEARL_PERSONALITY_BIN, os.X_OK):
                try:
                    subprocess.run([PEARL_PERSONALITY_BIN, "--tick"], capture_output=True, timeout=2)
                except Exception:
                    pass
        except Exception as e:
            # Fallback to pearl-cli
            fallback_res = execute_pearl_cli(prompt)
            send_sse(fallback_res, done=True, full=fallback_res)

    def log_message(self, format, *args):
        """Quiet logging to stdout."""
        sys.stdout.write(f"[pearl-server] {self.address_string()} - {format % args}\n")
        sys.stdout.flush()

# ---------------------------------------------------------
# Main Server Runner
# ---------------------------------------------------------

def main():
    server = ThreadingHTTPServer((HOST, PORT), PearlRequestHandler)
    print(f"==================================================")
    print(f" Pearl Local Server running on http://{HOST}:{PORT}")
    print(f" Native macOS Liquid Glass Web UI: http://{HOST}:{PORT}/")
    print(f" REST Status API: http://{HOST}:{PORT}/api/status")
    print(f" REST Chat API: http://{HOST}:{PORT}/api/chat")
    print(f" REST Notes API: http://{HOST}:{PORT}/api/notes")
    print(f"==================================================")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[pearl-server] Shutting down gracefully...")
        server.server_close()

if __name__ == "__main__":
    main()
