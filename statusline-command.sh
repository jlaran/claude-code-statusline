#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract values from JSON
project_dir_raw=$(echo "$input" | jq -r '.workspace.project_dir')
# Truncate home directory to ~ for display only
project_dir="${project_dir_raw/#$HOME/~}"
model_name=$(echo "$input" | jq -r '.model.display_name')
version=$(echo "$input" | jq -r '.version')
output_style=$(echo "$input" | jq -r '.output_style.name')
session_id=$(echo "$input" | jq -r '.session_id')
transcript_path=$(echo "$input" | jq -r '.transcript_path')

# Get git branch (skip optional locks) - use raw path for filesystem operations
git_branch=""
if [ -d "$project_dir_raw/.git" ]; then
    git_branch=$(cd "$project_dir_raw" && git --no-optional-locks branch --show-current 2>/dev/null)
    if [ -z "$git_branch" ]; then
        git_branch="(detached)"
    fi
fi

# Get git status (local/remote)
git_status=""
if [ -n "$git_branch" ] && [ "$git_branch" != "(detached)" ]; then
    cd "$project_dir_raw"

    # Check if there are uncommitted changes
    if ! git --no-optional-locks diff-index --quiet HEAD 2>/dev/null; then
        git_status="🔶 local changes"
    else
        # Check remote status
        git --no-optional-locks fetch --dry-run 2>/dev/null
        local_commit=$(git --no-optional-locks rev-parse @ 2>/dev/null)
        remote_commit=$(git --no-optional-locks rev-parse @{u} 2>/dev/null)

        if [ "$local_commit" = "$remote_commit" ]; then
            git_status="✅ synced"
        elif [ -z "$remote_commit" ]; then
            git_status="📍 local only"
        else
            base_commit=$(git --no-optional-locks merge-base @ @{u} 2>/dev/null)
            if [ "$local_commit" = "$base_commit" ]; then
                git_status="⬇️ behind"
            elif [ "$remote_commit" = "$base_commit" ]; then
                git_status="⬆️ ahead"
            else
                git_status="🔀 diverged"
            fi
        fi
    fi
fi

# Get last user prompt from transcript (JSONL format)
last_prompt=""
if [ -n "$transcript_path" ] && [ "$transcript_path" != "null" ] && [ -f "$transcript_path" ]; then
    # Extract last user-typed message, filtering out tool results and system content
    # Handle both string content and array content (with text items)
    last_prompt=$(jq -rs '
        [.[] | select(.type == "user") |
            if .message.content | type == "string" then
                select(.message.content | startswith("<") | not) | .message.content
            elif .message.content | type == "array" then
                (.message.content | map(select(.type == "text") | .text) | join(" ")) | select(length > 0) | select(startswith("<") | not)
            else
                empty
            end
        ] | last // empty
    ' "$transcript_path" 2>/dev/null)

    # Truncate to 100 chars
    if [ -n "$last_prompt" ] && [ ${#last_prompt} -gt 100 ]; then
        last_prompt="${last_prompt:0:100}..."
    fi
fi

# Get conversation summary - only for resumed sessions
# Uses caching to persist the summary across statusline refreshes
conversation_summary=""
summary_cache_dir="/tmp/claude-statusline-cache"
summary_cache_file=""

mkdir -p "$summary_cache_dir" 2>/dev/null

if [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
    summary_cache_file="$summary_cache_dir/$session_id.summary"

    # Check if we have a cached summary for this session
    if [ -f "$summary_cache_file" ]; then
        conversation_summary=$(cat "$summary_cache_file" 2>/dev/null)
    fi
fi

# Only generate summary if not cached and transcript exists
if [ -z "$conversation_summary" ] && [ -n "$transcript_path" ] && [ "$transcript_path" != "null" ]; then
    # Check if this is a NEW session (empty or very few messages)
    # If so, look for the most recent PREVIOUS session transcript to summarize
    current_msg_count=0
    if [ -f "$transcript_path" ]; then
        current_msg_count=$(jq -rs '[.[] | select(.type == "user" or .type == "assistant")] | length' "$transcript_path" 2>/dev/null || echo "0")
    fi

    # If this is a new session (< 3 messages), look for previous session
    if [ "$current_msg_count" -lt 3 ]; then
        # Get the directory containing session transcripts for this project
        transcript_dir=$(dirname "$transcript_path")

        if [ -d "$transcript_dir" ]; then
            # Find the most recent previous session transcript (not the current one)
            current_filename=$(basename "$transcript_path")
            previous_transcript=$(ls -t "$transcript_dir"/*.jsonl 2>/dev/null | grep -v "$current_filename" | head -1)

            if [ -n "$previous_transcript" ] && [ -f "$previous_transcript" ]; then
                # Extract the last exchanges from the previous session
                last_exchanges=$(tail -500 "$previous_transcript" | jq -rs '
                    [.[] | select(.type == "user" or .type == "assistant") |
                        (if .message.content | type == "string" then
                            .message.content
                        elif .message.content | type == "array" then
                            (.message.content | map(select(.type == "text") | .text) | join(" "))
                        else
                            ""
                        end) as $text |
                        select(($text | length) > 5) |
                        select(($text | startswith("<")) | not) |
                        {type: .type, text: $text}
                    ] | .[-6:] | .[] |
                    if .type == "user" then
                        "USER: \(.text | .[0:100])"
                    else
                        "ASSISTANT: \(.text | .[0:100])"
                    end
                ' 2>/dev/null | grep -v '^$')

                # Generate summary for previous session
                if [ -n "$last_exchanges" ] && [ ${#last_exchanges} -gt 30 ]; then
                    summary_prompt="Previous session conversation:
$last_exchanges

Reply with ONLY a 5-8 word summary of what was worked on. No intro, no quotes, no explanation. Just the summary."

                    if command -v gtimeout &>/dev/null; then
                        conversation_summary=$(gtimeout 8s claude -p "$summary_prompt" --model haiku 2>/dev/null)
                    elif command -v timeout &>/dev/null; then
                        conversation_summary=$(timeout 8s claude -p "$summary_prompt" --model haiku 2>/dev/null)
                    else
                        conversation_summary=$(claude -p "$summary_prompt" --model haiku 2>/dev/null)
                    fi

                    # Clean up and cache the summary
                    if [ -n "$conversation_summary" ]; then
                        conversation_summary=$(echo "$conversation_summary" | sed -E '
                            s/^\*\*//; s/\*\*$//;
                            s/^"//; s/"$//;
                            s/^Summary: //i;
                            s/^Here.s the summary: //i;
                            s/^The summary is: //i;
                        ' | head -1)

                        if [ ${#conversation_summary} -gt 60 ]; then
                            conversation_summary="${conversation_summary:0:60}..."
                        fi

                        # Prefix to indicate it's from previous session
                        conversation_summary="Previous: $conversation_summary"

                        if [ -n "$summary_cache_file" ] && [ -n "$conversation_summary" ]; then
                            echo "$conversation_summary" > "$summary_cache_file" 2>/dev/null
                        fi
                    fi
                fi
            fi
        fi
    fi

    # If still no summary and transcript exists, check for resumed session (gap detection)
    if [ -z "$conversation_summary" ] && [ -f "$transcript_path" ]; then
        # Check if this is a resumed session by looking for a gap > 2 minutes between consecutive messages
        # This detects when the session was paused and later resumed
        show_summary=false
        gap_index=-1

        # Extract timestamps and find the largest gap between messages
        gap_info=$(tail -500 "$transcript_path" | jq -rs '
            [.[] | select(.type == "user" or .type == "assistant") | .timestamp // empty] |
            . as $ts |
            reduce range(1; length) as $i (
                {max_gap: 0, gap_index: -1};
                ($ts[$i] | split(".")[0] | gsub("T"; " ") | strptime("%Y-%m-%d %H:%M:%S") | mktime) as $curr |
                ($ts[$i-1] | split(".")[0] | gsub("T"; " ") | strptime("%Y-%m-%d %H:%M:%S") | mktime) as $prev |
                ($curr - $prev) as $gap |
                if $gap > .max_gap then {max_gap: $gap, gap_index: $i} else . end
            ) |
            "\(.max_gap) \(.gap_index)"
        ' 2>/dev/null)

        max_gap=$(echo "$gap_info" | cut -d' ' -f1)
        gap_index=$(echo "$gap_info" | cut -d' ' -f2)

        # If there's a gap > 2 minutes, it's a resumed session
        if [ -n "$max_gap" ] && [ "$max_gap" -gt 120 ] 2>/dev/null; then
            show_summary=true
        fi

        if [ "$show_summary" = true ]; then
            # Extract messages from BEFORE the gap (the previous session)
            # Use gap_index to get only messages before the resume point
            last_exchanges=$(tail -500 "$transcript_path" | jq -rs --argjson idx "$gap_index" '
                [.[] | select(.type == "user" or .type == "assistant")] |
                (if $idx > 0 then .[0:$idx] else . end) |
                [.[] |
                    (if .message.content | type == "string" then
                        .message.content
                    elif .message.content | type == "array" then
                        (.message.content | map(select(.type == "text") | .text) | join(" "))
                    else
                        ""
                    end) as $text |
                    select(($text | length) > 5) |
                    select(($text | startswith("<")) | not) |
                    {type: .type, text: $text}
                ] | .[-6:] | .[] |
                if .type == "user" then
                    "USER: \(.text | .[0:100])"
                else
                    "ASSISTANT: \(.text | .[0:100])"
                end
            ' 2>/dev/null | grep -v '^$')

            # Only summarize if we have meaningful content
            if [ -n "$last_exchanges" ] && [ ${#last_exchanges} -gt 30 ]; then
                summary_prompt="Previous conversation:
$last_exchanges

Reply with ONLY a 5-8 word summary of what was worked on. No intro, no quotes, no explanation. Just the summary."

                # Use gtimeout on macOS or timeout on Linux
                if command -v gtimeout &>/dev/null; then
                    conversation_summary=$(gtimeout 8s claude -p "$summary_prompt" --model haiku 2>/dev/null)
                elif command -v timeout &>/dev/null; then
                    conversation_summary=$(timeout 8s claude -p "$summary_prompt" --model haiku 2>/dev/null)
                else
                    conversation_summary=$(claude -p "$summary_prompt" --model haiku 2>/dev/null)
                fi

                # Clean up the response
                if [ -n "$conversation_summary" ]; then
                    conversation_summary=$(echo "$conversation_summary" | sed -E '
                        s/^\*\*//; s/\*\*$//;
                        s/^"//; s/"$//;
                        s/^Summary: //i;
                        s/^Here.s the summary: //i;
                        s/^The summary is: //i;
                    ' | head -1)

                    # Truncate if too long
                    if [ ${#conversation_summary} -gt 60 ]; then
                        conversation_summary="${conversation_summary:0:60}..."
                    fi

                    # Cache the summary for this session
                    if [ -n "$summary_cache_file" ] && [ -n "$conversation_summary" ]; then
                        echo "$conversation_summary" > "$summary_cache_file" 2>/dev/null
                    fi
                fi
            fi
        fi
    fi
fi

# Line 1: Project info, git, model, version, output style
line1="📁 $project_dir"

if [ -n "$git_branch" ]; then
    line1="$line1 | 🌿 $git_branch"
fi

if [ -n "$git_status" ]; then
    line1="$line1 | $git_status"
fi

# Color the model name background (using ANSI escape codes)
model_colored=$(printf "\033[44m\033[97m %s \033[0m" "$model_name")
line1="$line1 | 🤖 $model_colored"

line1="$line1 | 📦 v$version"
line1="$line1 | 🎨 $output_style"

# Get running development servers for current project (auto-detect any port)
running_servers=""

get_icon_by_process() {
    local cmd=$1
    case "$cmd" in
        *node*|*npm*|*vite*)  echo "🌐" ;;   # Node/Frontend (globe)
        *python*|*uvicorn*)   echo "🐍" ;;   # Python/Backend
        *java*)               echo "☕" ;;   # Java
        *ruby*|*rails*)       echo "💎" ;;   # Ruby
        *go*)                 echo "🔷" ;;   # Go
        *)                    echo "🔹" ;;   # Default
    esac
}

# Find all TCP listening ports for processes in the current project
# Use lsof with LISTEN filter to only get servers, not clients
while IFS= read -r line; do
    [ -z "$line" ] && continue
    port=$(echo "$line" | awk '{print $9}' | sed 's/.*://')
    pid=$(echo "$line" | awk '{print $2}')

    # Get full command line to check if it's from project directory
    cmd_full=$(ps -p "$pid" -o args= 2>/dev/null)
    cmd_name=$(ps -p "$pid" -o comm= 2>/dev/null)

    # Skip if we can't get process info
    [ -z "$cmd_full" ] && continue

    # Check if process command line references the project directory
    # OR if it's a common dev server (uvicorn, vite, npm, node) we'll include it
    is_project_server=false

    # Method 1: Check if command line contains project path
    if echo "$cmd_full" | grep -q "$project_dir_raw"; then
        is_project_server=true
    fi

    # Method 2: For macOS, try to get cwd via lsof (works for some processes)
    if [ "$is_project_server" = false ]; then
        proc_cwd=$(lsof -p "$pid" -Fn 2>/dev/null | grep '^ncwd' | sed 's/^ncwd//' | head -1)
        if [ -z "$proc_cwd" ]; then
            # Alternative: look for 'cwd' in the fd column
            proc_cwd=$(lsof -p "$pid" 2>/dev/null | awk '$4=="cwd" {print $9}' | head -1)
        fi
        if [ -n "$proc_cwd" ] && echo "$proc_cwd" | grep -q "$project_dir_raw"; then
            is_project_server=true
        fi
    fi

    # Method 3: Check parent process tree for project directory association
    if [ "$is_project_server" = false ]; then
        # Get parent PID and check if any ancestor was started from project dir
        ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
        if [ -n "$ppid" ] && [ "$ppid" != "1" ]; then
            parent_cmd=$(ps -p "$ppid" -o args= 2>/dev/null)
            if echo "$parent_cmd" | grep -q "$project_dir_raw"; then
                is_project_server=true
            fi
        fi
    fi

    if [ "$is_project_server" = true ]; then
        # Check if this port is already in the list (avoid duplicates)
        if ! echo "$running_servers" | grep -q "localhost:$port"; then
            icon=$(get_icon_by_process "$cmd_full")
            url="http://localhost:$port"
            # OSC 8 hyperlink format using $'...' for escape sequences
            # Format: ESC ] 8 ; ; URL BEL TEXT ESC ] 8 ; ; BEL
            esc=$'\033'
            bel=$'\007'
            clickable_link="${esc}]8;;${url}${bel}${url}${esc}]8;;${bel}"
            if [ -n "$running_servers" ]; then
                running_servers="$running_servers | $icon $clickable_link"
            else
                running_servers="$icon $clickable_link"
            fi
        fi
    fi
done < <(lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | grep -v "^COMMAND" | awk '!seen[$9]++' | sort -t: -k2 -n)

if [ -n "$running_servers" ]; then
    line1="$line1 | $running_servers"
fi

# Line 2: Last user prompt
line2=""
if [ -n "$last_prompt" ]; then
    line2="→ $last_prompt"
fi

# Line 3: Conversation summary
line3=""
if [ -n "$conversation_summary" ]; then
    line3="📝 ($conversation_summary)"
fi

# Function to generate progress bar
# Usage: generate_bar <percentage> <total_width> <fill_char> <empty_char>
generate_bar() {
    local pct=$1
    local width=${2:-10}
    local fill_char=${3:-"="}
    local empty_char=${4:-"-"}

    local filled=$((pct * width / 100))
    local empty=$((width - filled))

    local bar=""
    for ((i=0; i<filled; i++)); do bar+="$fill_char"; done
    for ((i=0; i<empty; i++)); do bar+="$empty_char"; done

    echo "[$bar]"
}

# Line 4: Context window usage
context_used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d'.' -f1)
context_remaining_pct=$(echo "$input" | jq -r '.context_window.remaining_percentage // 0' | cut -d'.' -f1)
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')

# Ensure we have valid numbers
[ -z "$context_used_pct" ] || [ "$context_used_pct" = "null" ] && context_used_pct=0
[ -z "$context_remaining_pct" ] || [ "$context_remaining_pct" = "null" ] && context_remaining_pct=100
[ -z "$context_size" ] || [ "$context_size" = "null" ] && context_size=0
[ -z "$input_tokens" ] || [ "$input_tokens" = "null" ] && input_tokens=0

# Calculate remaining tokens
remaining_tokens=$((context_size - input_tokens))
[ "$remaining_tokens" -lt 0 ] 2>/dev/null && remaining_tokens=0

# Format remaining tokens (e.g., 150000 -> 150K)
format_tokens() {
    local tokens=$1
    if [ "$tokens" -ge 1000000 ] 2>/dev/null; then
        echo "$(echo "$tokens" | awk '{printf "%.1fM", $1/1000000}')"
    elif [ "$tokens" -ge 1000 ] 2>/dev/null; then
        echo "$(echo "$tokens" | awk '{printf "%.0fK", $1/1000}')"
    else
        echo "$tokens"
    fi
}

remaining_tokens_fmt=$(format_tokens "$remaining_tokens")

# Generate context bar (inverted - showing remaining)
context_bar=$(generate_bar "$context_remaining_pct" 8)

# Color based on remaining (green >50%, yellow 20-50%, red <20%)
if [ "$context_remaining_pct" -gt 50 ] 2>/dev/null; then
    ctx_color="\033[32m"  # Green
elif [ "$context_remaining_pct" -gt 20 ] 2>/dev/null; then
    ctx_color="\033[33m"  # Yellow
else
    ctx_color="\033[31m"  # Red
fi
reset_color="\033[0m"

# ============================================
# DAILY RATE LIMIT TRACKING
# ============================================
# Configure reset hour (24h format) - defaults to 2:00 AM based on Claude platform
RESET_HOUR=${CLAUDE_RESET_HOUR:-2}
RESET_MINUTE=${CLAUDE_RESET_MINUTE:-0}

current_hour=$(date +%H | sed 's/^0//')
current_min=$(date +%M | sed 's/^0//')
current_time_mins=$((current_hour * 60 + current_min))
reset_time_mins=$((RESET_HOUR * 60 + RESET_MINUTE))

# Calculate minutes until daily reset
if [ $current_time_mins -lt $reset_time_mins ]; then
    mins_until_reset=$((reset_time_mins - current_time_mins))
    mins_since_last_reset=$((24 * 60 - reset_time_mins + current_time_mins))
else
    mins_until_reset=$((24 * 60 - current_time_mins + reset_time_mins))
    mins_since_last_reset=$((current_time_mins - reset_time_mins))
fi

# Calculate daily usage percentage (time-based approximation)
daily_usage_pct=$((mins_since_last_reset * 100 / (24 * 60)))
[ "$daily_usage_pct" -gt 100 ] 2>/dev/null && daily_usage_pct=100

# Format time until daily reset
hours_until=$((mins_until_reset / 60))
mins_until=$((mins_until_reset % 60))

# Format daily reset time for display (12h AM/PM)
format_time_12h() {
    local hour=$1
    local minute=$2
    local min_padded=$(printf "%02d" "$minute")
    if [ "$hour" -eq 0 ]; then
        echo "12:${min_padded} AM"
    elif [ "$hour" -lt 12 ]; then
        echo "${hour}:${min_padded} AM"
    elif [ "$hour" -eq 12 ]; then
        echo "12:${min_padded} PM"
    else
        echo "$((hour - 12)):${min_padded} PM"
    fi
}

daily_reset_display=$(format_time_12h "$RESET_HOUR" "$RESET_MINUTE")

# Color for daily usage (green <50%, yellow 50-80%, red >80%)
if [ "$daily_usage_pct" -lt 50 ] 2>/dev/null; then
    daily_color="\033[32m"  # Green
elif [ "$daily_usage_pct" -lt 80 ] 2>/dev/null; then
    daily_color="\033[33m"  # Yellow
else
    daily_color="\033[31m"  # Red
fi

# ============================================
# WEEKLY RATE LIMIT TRACKING
# ============================================
# Weekly reset: Monday 10:59 AM based on Claude platform
# Configure: CLAUDE_WEEKLY_RESET_DAY (1=Mon, 2=Tue, etc.)
WEEKLY_RESET_DAY=${CLAUDE_WEEKLY_RESET_DAY:-1}
WEEKLY_RESET_HOUR=${CLAUDE_WEEKLY_RESET_HOUR:-10}
WEEKLY_RESET_MINUTE=${CLAUDE_WEEKLY_RESET_MINUTE:-59}

current_day_of_week=$(date +%u)  # 1=Mon, 7=Sun
current_epoch=$(date +%s)

# Calculate next weekly reset timestamp
days_until_weekly_reset=$(( (WEEKLY_RESET_DAY - current_day_of_week + 7) % 7 ))

# If today is reset day, check if we've passed the reset time
if [ "$days_until_weekly_reset" -eq 0 ]; then
    weekly_reset_today_mins=$((WEEKLY_RESET_HOUR * 60 + WEEKLY_RESET_MINUTE))
    if [ "$current_time_mins" -ge "$weekly_reset_today_mins" ]; then
        days_until_weekly_reset=7  # Next week
    fi
fi

# Calculate minutes until weekly reset
mins_until_weekly_reset=$((days_until_weekly_reset * 24 * 60 + (WEEKLY_RESET_HOUR * 60 + WEEKLY_RESET_MINUTE) - current_time_mins))
[ "$mins_until_weekly_reset" -lt 0 ] && mins_until_weekly_reset=$((mins_until_weekly_reset + 7 * 24 * 60))

# Calculate weekly usage percentage (time-based)
mins_in_week=$((7 * 24 * 60))
mins_since_weekly_reset=$((mins_in_week - mins_until_weekly_reset))
weekly_usage_pct=$((mins_since_weekly_reset * 100 / mins_in_week))
[ "$weekly_usage_pct" -gt 100 ] 2>/dev/null && weekly_usage_pct=100
[ "$weekly_usage_pct" -lt 0 ] 2>/dev/null && weekly_usage_pct=0

# Get the day name for weekly reset
get_day_name() {
    case $1 in
        0) echo "Sun" ;;
        1) echo "Mon" ;;
        2) echo "Tue" ;;
        3) echo "Wed" ;;
        4) echo "Thu" ;;
        5) echo "Fri" ;;
        6) echo "Sat" ;;
        7) echo "Sun" ;;
    esac
}

weekly_reset_day_name=$(get_day_name "$WEEKLY_RESET_DAY")
weekly_reset_time=$(format_time_12h "$WEEKLY_RESET_HOUR" "$WEEKLY_RESET_MINUTE")

# Color for weekly usage
if [ "$weekly_usage_pct" -lt 50 ] 2>/dev/null; then
    weekly_color="\033[32m"  # Green
elif [ "$weekly_usage_pct" -lt 80 ] 2>/dev/null; then
    weekly_color="\033[33m"  # Yellow
else
    weekly_color="\033[31m"  # Red
fi

# ============================================
# BUILD LINE 4 (Context + Usage Info)
# ============================================

# Format daily reset countdown
if [ "$hours_until" -gt 0 ]; then
    daily_reset_countdown="${hours_until}h ${mins_until}m"
else
    daily_reset_countdown="${mins_until}m"
fi

# Format weekly reset countdown
days_until=$((mins_until_weekly_reset / (24 * 60)))
hours_until_weekly=$(( (mins_until_weekly_reset % (24 * 60)) / 60 ))
mins_until_weekly=$((mins_until_weekly_reset % 60))

if [ "$days_until" -gt 0 ]; then
    weekly_reset_countdown="${days_until}d ${hours_until_weekly}h"
else
    weekly_reset_countdown="${hours_until_weekly}h ${mins_until_weekly}m"
fi

# Combined context and usage line
line4="🧠 Context: ${ctx_color}${remaining_tokens_fmt} (${context_remaining_pct}%)${reset_color} ${context_bar}"
line4="$line4 | 📊 Daily: Resets in ${daily_reset_countdown} (${daily_reset_display})"
line4="$line4 | 📅 Weekly: Resets in ${weekly_reset_countdown} (${weekly_reset_day_name} ${weekly_reset_time})"

# Output all lines (use -e to interpret escape sequences for clickable links)
echo -e "$line1"
if [ -n "$line2" ]; then
    echo "$line2"
fi
if [ -n "$line3" ]; then
    echo "$line3"
fi
if [ -n "$line4" ]; then
    echo -e "$line4"
fi
