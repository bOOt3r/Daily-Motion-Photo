#!/data/data/com.termux/files/usr/bin/bash

# --- CONFIGURATION ---
TARGET_DATE="$1"
[ -z "$TARGET_DATE" ] && TARGET_DATE=$(date +%Y%m%d)

DCIM_PATH="/sdcard/DCIM/Camera"
WORK_DIR="/sdcard/Tasker/DailyMovie/temp_videos"
OUTPUT_DIR="/sdcard/Tasker/DailyMovie/movie"
OUTPUT_FILE="$OUTPUT_DIR/Movie_$TARGET_DATE.mp4"
LIST_FILE="$WORK_DIR/stitch_list.txt"
LOG_FILE="/sdcard/Tasker/DailyMovie/movie_log.txt"

exec > "$LOG_FILE" 2>&1

echo "--- Session started at $(date) for $TARGET_DATE ---"

# Standard Settings
WIDTH=1440
HEIGHT=1080
FPS=30
FFMPEG="/data/data/com.termux/files/usr/bin/ffmpeg"
GREP="/data/data/com.termux/files/usr/bin/grep"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
rm -f "$LIST_FILE"

# ==============================================================================
# PART 1: IDENTIFY THE SESSION
# ==============================================================================

# Get all Motion Photos sorted by name (which is chronological for PXL_ filenames)
mapfile -t ALL_PHOTOS < <(ls "$DCIM_PATH"/PXL_*MP.jpg 2>/dev/null | sort)

if [ ${#ALL_PHOTOS[@]} -eq 0 ]; then
    echo "Error: No photos found in DCIM."
    exit 0
fi

# Find the index of the first photo taken on the TARGET_DATE
START_INDEX=-1
for i in "${!ALL_PHOTOS[@]}"; do
    if [[ "${ALL_PHOTOS[$i]}" == *"$TARGET_DATE"* ]]; then
        START_INDEX=$i
        break
    fi
done

if [ "$START_INDEX" -eq -1 ]; then
    echo "No photos found for date $TARGET_DATE. Exiting."
    exit 0
fi

# Build the session list based on the 60-minute rule
SESSION_FILES=()
LAST_UNIX_TIME=0

for (( i=START_INDEX; i<${#ALL_PHOTOS[@]}; i++ )); do
    FILE="${ALL_PHOTOS[$i]}"
    
    # Extract timestamp from filename PXL_YYYYMMDD_HHMMSS
    # We grab the YYYYMMDD and HHMMSS parts
    FILE_BASE=$(basename "$FILE")
    TS_PART=$(echo "$FILE_BASE" | cut -d'_' -f2,3)
    # Convert to Unix Epoch for math (GNU date in Termux handles this)
    CURRENT_UNIX_TIME=$(date -d "${TS_PART/_/ }" +%s 2>/dev/null)

    if [ "$LAST_UNIX_TIME" -eq 0 ]; then
        # This is our first photo of the day
        SESSION_FILES+=("$FILE")
        LAST_UNIX_TIME=$CURRENT_UNIX_TIME
    else
        DIFF=$((CURRENT_UNIX_TIME - LAST_UNIX_TIME))
        if [ "$DIFF" -le 3600 ]; then
            # Less than 1 hour gap, keep the session alive
            SESSION_FILES+=("$FILE")
            LAST_UNIX_TIME=$CURRENT_UNIX_TIME
        else
            # Gap too large! Session ended.
            echo "Session boundary reached at gap of $((DIFF/60)) minutes."
            break
        fi
    fi
done

echo "Found ${#SESSION_FILES[@]} photos for this session."

# ==============================================================================
# PART 2: PROCESS SESSION PHOTOS
# ==============================================================================
count=0
for img in "${SESSION_FILES[@]}"; do
    base_name="$(basename "$img" .jpg)"
    raw_temp="$WORK_DIR/${base_name}_raw.mp4"
    fixed_file="$WORK_DIR/${base_name}_fixed.mp4"

    if [ -s "$fixed_file" ]; then
        echo "file '$fixed_file'" >> "$LIST_FILE"
        count=$((count+1))
        continue
    fi

    # Extraction Logic (same as your original)
    offset=$($GREP -a -b -oP "\x00\x00\x00\x18\x66\x74\x79\x70" "$img" | tail -1 | cut -d: -f1)
    if [ -z "$offset" ]; then
        offset=$($GREP -a -b -o "ftypisom" "$img" | tail -1 | cut -d: -f1)
        [ -n "$offset" ] && offset=$((offset - 4))
    fi

    [ -z "$offset" ] && continue

    dd if="$img" of="$raw_temp" bs=1 skip="$offset" status=none 2>/dev/null
    
    if [ -s "$raw_temp" ]; then
        $FFMPEG -y -i "$raw_temp" \
            -map 0:v:0 \
            -vf "scale=$WIDTH:$HEIGHT:force_original_aspect_ratio=decrease,pad=$WIDTH:$HEIGHT:(ow-iw)/2:(oh-ih)/2,setsar=1" \
            -c:v libx264 -crf 26 -preset ultrafast \
            -r "$FPS" -video_track_timescale 90000 -pix_fmt yuv420p \
            -an \
            "$fixed_file" >/dev/null 2>&1
        rm -f "$raw_temp"
    fi

    if [ -s "$fixed_file" ]; then
        echo "file '$fixed_file'" >> "$LIST_FILE"
        count=$((count+1))
    fi
done

# ==============================================================================
# PART 3: STITCH & HAND-OFF
# ==============================================================================

if [ "$count" -eq 0 ]; then
    echo "No clips found for this session. Cleaning up."
    # We clear the variable in Tasker so it knows nothing was created
    tasker_setvar -n LatestMovie -v "NONE" 2>/dev/null
    exit 0
fi

echo "Stitching $count clips into $OUTPUT_FILE..."

# 1. Format date for Metadata (YYYYMMDD -> YYYY-MM-DD)
META_DATE="${TARGET_DATE:0:4}-${TARGET_DATE:4:2}-${TARGET_DATE:6:2}"

# 2. Run the actual FFMPEG Stitch
# We use -c copy because the individual clips were already standardized in Part 2
$FFMPEG -y -f concat -safe 0 -i "$LIST_FILE" \
    -c copy \
    -metadata creation_time="$META_DATE 23:59:00" \
    "$OUTPUT_FILE" >/dev/null 2>&1

# 3. Verify and Notify Tasker
if [ -e "$OUTPUT_FILE" ]; then
    echo "Success. Saved to $OUTPUT_FILE"
    
    # Trigger Android Media Scanner so it shows up in Gallery
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$OUTPUT_FILE" >/dev/null 2>&1
    
    # SET TASKER VARIABLE: This is the magic part for your Move action
    # This allows Tasker to use %LatestMovie as the "From" path
    tasker_setvar -n LatestMovie -v "$OUTPUT_FILE" 2>/dev/null
else
    echo "Error: FFMPEG failed to create the output file."
    tasker_setvar -n LatestMovie -v "ERROR" 2>/dev/null
fi

# 4. Self-Cleaning
# Remove any temp videos older than 2 days to save space
find "$WORK_DIR" -type f -name "*_fixed.mp4" -mtime +2 -delete