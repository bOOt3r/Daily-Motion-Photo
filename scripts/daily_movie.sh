#!/data/data/com.termux/files/usr/bin/bash

# Re-exec under bash if invoked via sh/dash (Tasker/su sometimes bypasses shebang).
if [ -z "$BASH_VERSION" ]; then
    exec /data/data/com.termux/files/usr/bin/bash "$0" "$@"
fi

# Force Termux binaries to take precedence over Android's toybox/system ones.
# Without this, `date`, `sed`, `find`, etc. resolve to /system/bin versions which
# behave very differently (e.g. toybox `date -d "yesterday"` fails).
export PATH="/data/data/com.termux/files/usr/bin:$PATH"

# ==============================================================================
# DAILY MOVIE: AUTO-SYNC WITH LOGGING
# ------------------------------------------------------------------------------
# Logical-day rule: photos taken before 04:00 belong to the PREVIOUS calendar
# day's movie. Photos at/after 04:00 belong to the CURRENT calendar day.
# This matches the Tasker job that archives the movie at 04:00.
# ==============================================================================

# --- CONFIGURATION ---
DCIM_PATH="/sdcard/DCIM/Camera"
WORK_DIR="/sdcard/Tasker/DailyMovie/temp_videos"
OUTPUT_DIR="/sdcard/Tasker/DailyMovie/movie"
LOG_DIR="/sdcard/Tasker/DailyMovie/logs"
LIST_FILE="$WORK_DIR/stitch_list.txt"
LOCK_FILE="$WORK_DIR/.daily_movie.lock"
CUTOFF_HOUR=4   # photos before this hour belong to previous calendar day

# Standard Settings
WIDTH=1440
HEIGHT=1080
FPS=30

# --- BINARIES ---
FFMPEG="/data/data/com.termux/files/usr/bin/ffmpeg"
GREP="/data/data/com.termux/files/usr/bin/grep"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR" "$LOG_DIR"

# --- LOGGING (per-day, append) ---
# Use today's logical day for the log filename, derived from current time.
NOW_HOUR=$(date +%H)
if [ "$((10#$NOW_HOUR))" -lt "$CUTOFF_HOUR" ]; then
    LOG_DATE=$(date -d "yesterday" +%Y%m%d)
else
    LOG_DATE=$(date +%Y%m%d)
fi
LOG_FILE="$LOG_DIR/movie_log_$LOG_DATE.txt"
exec >> "$LOG_FILE" 2>&1

echo ""
echo "================================================================"
echo "--- Run started at $(date) ---"
echo "================================================================"

# --- SANITY CHECKS ---
if [ ! -d "$DCIM_PATH" ]; then
    echo "ERROR: DCIM path not found: $DCIM_PATH"
    exit 2
fi
if [ ! -x "$FFMPEG" ]; then
    echo "ERROR: ffmpeg not found at $FFMPEG"
    exit 2
fi

# --- LOCK (prevent concurrent runs) ---
if [ -e "$LOCK_FILE" ]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "Another run is in progress (pid $LOCK_PID). Exiting."
        exit 0
    else
        echo "Stale lock file found, removing."
        rm -f "$LOCK_FILE"
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

rm -f "$LIST_FILE"

# --- DATE HELPERS ---
NOW_HOUR=$(date +%H)

# Check if a manual date argument (YYYYMMDD) was provided
if [ -n "$1" ]; then
    TARGET_DATE="$1"
    # Parse the manually provided date to set the proper calendar bounds for the glob
    y=${TARGET_DATE:0:4} m=${TARGET_DATE:4:2} d=${TARGET_DATE:6:2}
    TODAY=$(date -d "$y-$m-$d +1 day" +%Y%m%d)
    YESTERDAY="$TARGET_DATE"
    echo "Manual override triggered for logical day: $TARGET_DATE"
else
    # Auto-detect based on current clock time
    TODAY=$(date +%Y%m%d)
    YESTERDAY=$(date -d "yesterday" +%Y%m%d)

    if [ "$((10#$NOW_HOUR))" -lt "$CUTOFF_HOUR" ]; then
        TARGET_DATE="$YESTERDAY"
    else
        TARGET_DATE="$TODAY"
    fi
fi

# Given a Pixel filename like PXL_20250521_153012345MP.jpg, return the
# logical-day YYYYMMDD according to the 04:00 cutoff rule.
logical_day_for_file() {
    local fname="$1"
    local file_date file_hour
    file_date=$(echo "$fname" | sed -n 's/^PXL_\([0-9]\{8\}\)_.*/\1/p')
    file_hour=$(echo "$fname" | sed -n 's/^PXL_[0-9]\{8\}_\([0-9]\{2\}\).*/\1/p')
    if [ -z "$file_date" ] || [ -z "$file_hour" ]; then
        echo ""
        return
    fi
    # Use file_hour here so individual photos are grouped correctly!
    if [ "$((10#$file_hour))" -lt "$CUTOFF_HOUR" ]; then
        # Belongs to previous calendar day
        local y=${file_date:0:4} m=${file_date:4:2} d=${file_date:6:2}
        date -d "$y-$m-$d 12:00:00 -1 day" +%Y%m%d
    else
        echo "$file_date"
    fi
}

OUTPUT_FILE="$OUTPUT_DIR/Movie_$TARGET_DATE.mp4"
echo "Target logical day: $TARGET_DATE"
echo "Output: $OUTPUT_FILE"

# ==============================================================================
# PART 0: SELF-CLEANING
# ==============================================================================
# Remove temp files that don't belong to today's or yesterday's logical day.
# (We need both because a 02:00 run still processes yesterday's photos.)
find "$WORK_DIR" -type f -name "*.mp4" \
    ! -name "*${TODAY}*" ! -name "*${YESTERDAY}*" -delete

# ==============================================================================
# PART 1: SYNC DELETIONS
# ==============================================================================
for cached_file in "$WORK_DIR"/*_fixed.mp4; do
    [ -e "$cached_file" ] || continue

    base_name=$(basename "$cached_file" _fixed.mp4)
    original_jpg="$DCIM_PATH/${base_name}.jpg"

    if [ ! -e "$original_jpg" ]; then
        echo "Deleting orphan clip: $base_name"
        rm -f "$cached_file"
    fi
done

# ==============================================================================
# PART 2: PROCESS NEW PHOTOS
# ==============================================================================
# Glob both yesterday and today, then keep only those whose LOGICAL day matches
# TARGET_DATE. Sort by capture time so the movie is chronological.
count=0
ffmpeg_failures=0

# Build a list of candidate photos for TARGET_DATE
mapfile -t candidates < <(
    for img in "$DCIM_PATH"/PXL_"$YESTERDAY"*MP.jpg "$DCIM_PATH"/PXL_"$TODAY"*MP.jpg; do
        [ -e "$img" ] || continue
        fname=$(basename "$img")
        ld=$(logical_day_for_file "$fname")
        if [ "$ld" = "$TARGET_DATE" ]; then
            echo "$img"
        fi
    done | sort
)

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "No photos found for logical day $TARGET_DATE."
    # Remove any stale movie that might exist for this day
    if [ -e "$OUTPUT_FILE" ]; then
        echo "Removing stale output: $OUTPUT_FILE"
        rm -f "$OUTPUT_FILE"
    fi
    exit 0
fi

echo "Found ${#candidates[@]} candidate photo(s) for $TARGET_DATE."

for img in "${candidates[@]}"; do
    base_name="$(basename "$img" .jpg)"
    raw_temp="$WORK_DIR/${base_name}_raw.mp4"
    fixed_file="$WORK_DIR/${base_name}_fixed.mp4"

    # --- CHECK CACHE ---
    if [ -s "$fixed_file" ]; then
        echo "Cached: $base_name"
        echo "file '$fixed_file'" >> "$LIST_FILE"
        count=$((count+1))
        continue
    fi

    # --- NEW FILE ---
    echo "Processing: $base_name"

    # 1. Extract embedded MP4
    offset=$($GREP -a -b -oP "\x00\x00\x00\x18\x66\x74\x79\x70" "$img" | tail -1 | cut -d: -f1)
    if [ -z "$offset" ]; then
        offset=$($GREP -a -b -o "ftypisom" "$img" | tail -1 | cut -d: -f1)
        [ -n "$offset" ] && offset=$((offset - 4))
    fi

    if [ -z "$offset" ]; then
        echo "  No embedded MP4 found in $base_name, skipping."
        continue
    fi

    dd if="$img" of="$raw_temp" bs=1 skip="$offset" status=none 2>/dev/null

    # 2. Standardize
    if [ -s "$raw_temp" ]; then
        $FFMPEG -y -i "$raw_temp" \
            -map 0:v:0 \
            -vf "scale=$WIDTH:$HEIGHT:force_original_aspect_ratio=decrease,pad=$WIDTH:$HEIGHT:(ow-iw)/2:(oh-ih)/2,setsar=1" \
            -c:v libx264 -crf 26 -preset ultrafast \
            -r "$FPS" -video_track_timescale 90000 -pix_fmt yuv420p \
            -an \
            "$fixed_file" >/dev/null 2>&1
        ff_rc=$?
        rm -f "$raw_temp"
        if [ $ff_rc -ne 0 ]; then
            echo "  ffmpeg failed (rc=$ff_rc) for $base_name"
        fi
    fi

    if [ -s "$fixed_file" ]; then
        echo "file '$fixed_file'" >> "$LIST_FILE"
        count=$((count+1))
    else
        echo "  Failed to convert: $base_name"
        ffmpeg_failures=$((ffmpeg_failures+1))
    fi
done

# ==============================================================================
# PART 3: STITCH
# ==============================================================================
if [ "$count" -eq 0 ]; then
    echo "No usable clips. Cleaning up."
    rm -f "$OUTPUT_FILE"
    exit 0
fi

echo "Stitching $count clip(s)..."

# Format date for Metadata (YYYYMMDD -> YYYY-MM-DD)
META_DATE="${TARGET_DATE:0:4}-${TARGET_DATE:4:2}-${TARGET_DATE:6:2}"

# 1. Create the video. 23:59:00 sorts it as the last item of that day.
$FFMPEG -y -f concat -safe 0 -i "$LIST_FILE" \
    -c copy \
    -metadata creation_time="$META_DATE 23:59:00" \
    "$OUTPUT_FILE" >/dev/null 2>&1
stitch_rc=$?

# 2. Trigger media scan
if [ $stitch_rc -eq 0 ] && [ -e "$OUTPUT_FILE" ]; then
    echo "Triggering Media Scan..."
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$OUTPUT_FILE" >/dev/null 2>&1
    echo "Success. Saved to $OUTPUT_FILE"
    [ "$ffmpeg_failures" -gt 0 ] && echo "Note: $ffmpeg_failures clip(s) failed to convert this run."
    exit 0
else
    echo "ERROR: Stitch failed (rc=$stitch_rc). Output not created."
    exit 1
fi
