#!/usr/bin/env bash
# count-ts-lines.sh: Count lines in .ts and .tsx files, sorted by descending count

# Directory to search
TARGET_DIR="/Users/adeptima/Desktop/go/aino/monorepo/aino-core/src/app"

# Verify directory exists
if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Error: Directory '$TARGET_DIR' not found." >&2
  exit 1
fi

# Find files, count lines, sort by count descending, omit the total line
find "$TARGET_DIR" -type f \( -name '*.py' -o -name '*.tsx' \) -print0 \
  | xargs -0 wc -l \
  | sort -rn \
  | sed '/total [0-9]\+/d'
