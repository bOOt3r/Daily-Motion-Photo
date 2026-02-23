#!/data/data/com.termux/files/usr/bin/bash

# ==============================================================================
# DAILY MOVIE: AUTO-SYNC WITH LOGGING
# ==============================================================================

# --- CONFIGURATION ---
TARGET_DATE="$1"
[ -z "$TARGET_DATE" ] && TARGET_DATE=$(date +%Y%m%d)

DCIM_PATH="/sdcard/DCIM/Camera"
WORK_DIR="/sdcard/Tasker/DailyMovie/temp_videos"
OUTPUT_DIR="/sdcard/Tasker/DailyMovie/movie"
OUTPUT_FILE="$OUTPUT_DIR/Movie_$TARGET_DATE.mp4"
LIST_FILE="$WORK_DIR/stitch_list.txt"

# --- LOGGING ENABLED ---
# This saves all "echo" output to a file. 
# It overwrites each time, so it doesn't grow forever.
LOG_FILE="/sdcard/Tasker/DailyMovie/movie_log.txt"
exec > "$LOG_FILE" 2>&1

echo "--- Run started at $(date) for $TARGET_DATE ---"

# Standard Settings
WIDTH=1440
HEIGHT=1080
FPS=30

# --- BINARIES ---
FFMPEG="/data/data/com.termux/files/usr/bin/ffmpeg"
GREP="/data/data/com.termux/files/usr/bin/grep"

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
rm -f "$LIST_FILE"

# ==============================================================================
# PART 0: SELF-CLEANING
# ==============================================================================
# Removes temp files from previous days
find "$WORK_DIR" -type f -name "*.mp4" ! -name "*$TARGET_DATE*" -delete

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
count=0

for img in "$DCIM_PATH"/PXL_"$TARGET_DATE"*MP.jpg; do
    [ -e "$img" ] || break
    
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

    # 1. Extract
    offset=$($GREP -a -b -oP "\x00\x00\x00\x18\x66\x74\x79\x70" "$img" | tail -1 | cut -d: -f1)
    if [ -z "$offset" ]; then
        offset=$($GREP -a -b -o "ftypisom" "$img" | tail -1 | cut -d: -f1)
        [ -n "$offset" ] && offset=$((offset - 4))
    fi

    [ -z "$offset" ] && continue

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
            
        rm -f "$raw_temp"
    fi

    if [ -s "$fixed_file" ]; then
        echo "file '$fixed_file'" >> "$LIST_FILE"
        count=$((count+1))
    else
        echo "Failed to convert: $base_name"
    fi
done

# ==============================================================================
# PART 3: STITCH
# ==============================================================================
if [ "$count" -eq 0 ]; then
    echo "No clips remaining. Cleaning up."
    rm -f "$OUTPUT_FILE"
    exit 0
fi

echo "Stitching $count clips..."

# Format date for Metadata (YYYYMMDD -> YYYY-MM-DD)
META_DATE="${TARGET_DATE:0:4}-${TARGET_DATE:4:2}-${TARGET_DATE:6:2}"

# 1. Create the video
# We set time to 23:59:00 so it appears as the last item of the day in your timeline
$FFMPEG -y -f concat -safe 0 -i "$LIST_FILE" \
    -c copy \
    -metadata creation_time="$META_DATE 23:59:00" \
    "$OUTPUT_FILE" >/dev/null 2>&1

# 2. Force Android to scan the new file immediately
if [ -e "$OUTPUT_FILE" ]; then
    echo "Triggering Media Scan..."
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$OUTPUT_FILE" >/dev/null 2>&1
    echo "Success. Saved to $OUTPUT_FILE"
else
    echo "Error: Output file not created."
fi
