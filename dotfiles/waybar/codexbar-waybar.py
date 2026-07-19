#!/usr/bin/env python3
import json
import subprocess
import sys

try:
    res = subprocess.run(["codexbar", "usage", "--format", "json"], capture_output=True, text=True, check=True)
    data = json.loads(res.stdout)
except Exception as e:
    error_data = {
        "text": "󰚩 Err",
        "tooltip": f"Error running codexbar: {str(e)}",
        "class": "error"
    }
    print(json.dumps(error_data))
    sys.exit(0)

codex_left = None
gemini_5h_left = None
claude_weekly_left = None

tooltip_lines = []

for item in data:
    p_id = item.get("provider")
    usage = item.get("usage", {})
    if p_id == "codex":
        # Pick the first non-null window among primary/secondary/tertiary
        windows = []
        for key in ("primary", "secondary", "tertiary"):
            win = usage.get(key)
            if win:
                windows.append(win)
        if windows:
            main = windows[0]
            used = main.get("usedPercent", 0)
            codex_left = max(0, 100 - used)
            reset = main.get("resetDescription", "")
            label = "Session" if len(windows) > 1 else "Usage"
            tooltip_lines.append(f"󰭹 ChatGPT {label}: {codex_left:.0f}% left (resets {reset})")
        if len(windows) > 1:
            sec = windows[1]
            used_sec = sec.get("usedPercent", 0)
            sec_left = max(0, 100 - used_sec)
            reset_sec = sec.get("resetDescription", "")
            tooltip_lines.append(f"󰭹 ChatGPT Weekly: {sec_left:.0f}% left (resets {reset_sec})")
        # Try all pace keys, pick the first with a summary
        for pace_key in ("primary", "secondary", "tertiary"):
            pace = item.get("pace", {}).get(pace_key, {})
            if pace and pace.get("summary"):
                tooltip_lines.append(f"  Pace: {pace.get('summary')}")
                break
    elif p_id == "antigravity":
        extra = usage.get("extraRateWindows", [])
        tooltip_lines.append("")
        tooltip_lines.append("✨ Google Antigravity Limits:")
        for win in extra:
            title = win.get("title", "")
            w_data = win.get("window", {})
            used = w_data.get("usedPercent", 0)
            left = max(0, 100 - used)
            reset = w_data.get("resetDescription", "")
            if "Gemini 5-hour" in title:
                gemini_5h_left = left
            elif "Claude/GPT weekly" in title:
                claude_weekly_left = left
            tooltip_lines.append(f"  • {title}: {left:.1f}% left")
            if reset:
                # Clean up if it's too long
                tooltip_lines.append(f"    Reset: {reset}")

# Format status text
text_parts = []
if codex_left is not None:
    text_parts.append(f"󰭹 OPEN_AI {codex_left:.0f}%")
if gemini_5h_left is not None:
    text_parts.append(f"✨ GEMINI_5H {gemini_5h_left:.0f}%")
if claude_weekly_left is not None:
    text_parts.append(f"󰭹 CLAUDE_WEEKLY {claude_weekly_left:.0f}%")

text = " | ".join(text_parts)
tooltip = "\n".join(tooltip_lines)

waybar_data = {
    "text": text,
    "tooltip": tooltip,
    "class": "codexbar"
}
print(json.dumps(waybar_data))
