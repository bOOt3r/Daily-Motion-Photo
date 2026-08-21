# Daily Motion Photo for Android

A Bash script for Android that turns Google Pixel / Android **Motion Photos** into a single video.

The script is intended to run directly on the phone using **Termux** and **FFmpeg**. It can also be started automatically from **Tasker**, allowing a movie to be generated without manually opening Termux.

The original Motion Photos are left untouched.

The inspiration to this "project" came from an old digital camera i bought, you can read about it [here!](https://www.linkedin.com/feed/update/urn:li:activity:7412968056907276288/)

## What it does

The script processes Motion Photos stored in the phone's camera directory:

```text
/storage/emulated/0/DCIM/Camera
```

For each Motion Photo it:

1. Finds the embedded video portion of the Motion Photo.
2. Extracts the video clip.
3. Fixes/normalizes the clip with FFmpeg where required.
4. Rotates portrait clips when the filename identifies them as portrait.
5. Joins the resulting clips together.
6. Creates a final MP4 movie.

The finished movie is stored in:

```text
/storage/emulated/0/DCIM/Camera
```

## Does it require root?

**No.**

## Requirements

Termux
FFmpeg
grep

## Optional (but highly recommended)
Tasker
