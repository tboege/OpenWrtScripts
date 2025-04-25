#!/bin/sh

# Function to display detailed help
show_help() {
    cat << EOF
Usage: $0 [<archive.tar.gz>] [--no-cleanup] [--remove pattern1 pattern2 ...] [--help]

This script unpacks a tar.gz archive (if provided), redacts confidential information, removes specified files,
and creates a new redacted archive. The archive can be created using 'sysupgrade -b' on OpenWrt
systems to back up configuration files (e.g., 'sysupgrade -b /tmp/backup.tar.gz').

Options:
  <archive.tar.gz>      The input archive file to process (optional; if omitted, only help is shown with --help)
  --no-cleanup          Preserve the temporary working directory after processing
  --remove pattern1 ... Remove files matching the specified shell wildcard patterns
                        (e.g., "*.key", "etc/*.conf"). Patterns are matched recursively
                        against the full path within the archive.
  --help                Display this detailed help message

Examples:
  $0 backup.tar.gz
    Process backup.tar.gz and create redacted_backup.tar.gz
  $0 backup.tar.gz --no-cleanup
    Keep the temporary directory for inspection
  $0 backup.tar.gz --remove "*.he.fortunatus.dk.key" "etc/ssl/*"
    Remove all files matching the patterns and redact sensitive data
  $0 --help
    Show this help message without processing an archive

Note: Removed files are replaced with empty files suffixed with '_removed_by_REDACT'.
EOF
    exit 0
}

# Check if no arguments are provided (allow running with just options)
if [ $# -eq 0 ]; then
    echo "Usage: $0 [<archive.tar.gz>] [--no-cleanup] [--remove pattern1 pattern2 ...] [--help]"
    echo "Run with --help for detailed information"
    exit 1
fi

# Default to no archive unless provided
ARCHIVE=""
TEMP_DIR="temp_$(date +%s)"
CLEANUP=1
REMOVE_PATTERNS=""

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --no-cleanup)
            CLEANUP=0
            shift
            ;;
        --remove)
            shift
            while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
                REMOVE_PATTERNS="$REMOVE_PATTERNS $1"
                shift
            done
            ;;
        --help)
            show_help
            ;;
        *)
            if [ -z "$ARCHIVE" ] && [ -f "$1" ]; then
                ARCHIVE="$1"
                shift
            else
                echo "Unknown option or invalid archive: $1"
                echo "Usage: $0 [<archive.tar.gz>] [--no-cleanup] [--remove pattern1 pattern2 ...] [--help]"
                echo "Run with --help for detailed information"
                exit 1
            fi
            ;;
    esac
done

# If no archive is provided, proceed only if --help was used (already handled by show_help)
if [ -z "$ARCHIVE" ]; then
    echo "No archive provided and no valid options specified"
    echo "Usage: $0 [<archive.tar.gz>] [--no-cleanup] [--remove pattern1 pattern2 ...] [--help]"
    echo "Run with --help for detailed information"
    exit 1
fi

# Check if file exists
if [ ! -f "$ARCHIVE" ]; then
    echo "Error: File $ARCHIVE does not exist"
    exit 1
fi

# Create temporary directory and unpack
echo "Extracting $ARCHIVE to $TEMP_DIR"
mkdir "$TEMP_DIR"
tar -xzf "$ARCHIVE" -C "$TEMP_DIR"

# Remove specific files and replace with empty files
for file in \
    "$TEMP_DIR/etc/dropbear/dropbear_ed25519_host_key" \
    "$TEMP_DIR/etc/dropbear/dropbear_rsa_host_key" \
    "$TEMP_DIR/root/.ssh/id_dropbear" \
    "$TEMP_DIR/root/.ssh/id_dropbear.pub"
do
    if [ -e "$file" ]; then
        echo "Removing $file and creating ${file}_removed_by_REDACT"
        rm -rf "$file"
        mkdir -p "$(dirname "$file")"
        touch "${file}_removed_by_REDACT"
    fi
done

# Handle wildcard patterns from --remove
if [ -n "$REMOVE_PATTERNS" ]; then
    for pattern in $REMOVE_PATTERNS; do
        # Use find with full path to match patterns
        find "./$TEMP_DIR" -type f -path "*$pattern" | while read -r file; do
            if [ -e "$file" ]; then
                clean_file="$file"
                echo "Removing $clean_file and creating ${clean_file}_removed_by_REDACT"
                rm -rf "$file"
                mkdir -p "$(dirname "$clean_file")"
                touch "${clean_file}_removed_by_REDACT"
            fi
        done
    done
fi

# Search and replace confidential information with logging (excluding /etc/shadow)
find "$TEMP_DIR" -type f -exec sh -c '
    for file do
        # Skip redaction for usr/local/bin/redact.sh
        if [ "${file#*/}" = "usr/local/bin/redact.sh" ]; then
            continue
        fi

        # Count replacements for each pattern
        changes1=$(sed "s/option key '\''[^'\'']*'\''/option key '\''<REDACTED>'\''/g" "$file" | cmp - "$file" | wc -l)
        changes2=$(sed "s/option private_key '\''[^'\'']*'\''/option private_key '\''<REDACTED>'\''/g" "$file" | cmp - "$file" | wc -l)
        changes3=$(sed "s/list credentials \+[[:alnum:]_]*KEY=\"[^\"]*\"/list credentials [[:alnum:]_]*KEY=\"<REDACTED>\"/gI" "$file" | cmp - "$file" | wc -l)
        changes4=$(sed "s/list credentials \+[[:alnum:]_]*PASS=\"[^\"]*\"/list credentials [[:alnum:]_]*PASS=\"<REDACTED>\"/gI" "$file" | cmp - "$file" | wc -l)
        changes5=$(sed "s/--password=[^[:space:]\"]*\"*/--password=<REDACTED>/g" "$file" | cmp - "$file" | wc -l)
        changes6=$(sed "s/--password[[:space:]]\+[^[:space:]]\+/--password <REDACTED>/g" "$file" | cmp - "$file" | wc -l)
        changes8=$(sed "s/option mobility_domain '\''[^'\'']*'\''/option mobility_domain '\''<REDACTED>'\''/g" "$file" | cmp - "$file" | wc -l)

        # Apply changes if any
        if [ "$changes1" -gt 0 ] || [ "$changes2" -gt 0 ] || [ "$changes3" -gt 0 ] || [ "$changes4" -gt 0 ] || [ "$changes5" -gt 0 ] || [ "$changes6" -gt 0 ] || [ "$changes8" -gt 0 ]; then
            echo "Redacting confidential information in $file"
            sed -i \
                -e "s/option key '\''[^'\'']*'\''/option key '\''<REDACTED>'\''/g" \
                -e "s/option private_key '\''[^'\'']*'\''/option private_key '\''<REDACTED>'\''/g" \
                -e "s/list credentials \+[[:alnum:]_]*KEY=\"[^\"]*\"/list credentials [[:alnum:]_]*KEY=\"<REDACTED>\"/gI" \
                -e "s/list credentials \+[[:alnum:]_]*PASS=\"[^\"]*\"/list credentials [[:alnum:]_]*PASS=\"<REDACTED>\"/gI" \
                -e "s/--password=[^[:space:]\"]*\"*/--password=<REDACTED>/g" \
                -e "s/--password[[:space:]]\+[^[:space:]]\+/--password <REDACTED>/g" \
                -e "s/option mobility_domain '\''[^'\'']*'\''/option mobility_domain '\''<REDACTED>'\''/g" \
                "$file"
        fi
    done
' sh {} \;

# Special handling for /etc/shadow: replace hash in second field if longer than 3 characters
SHADOW_FILE="$TEMP_DIR/etc/shadow"
if [ -f "$SHADOW_FILE" ]; then
    echo "Checking $SHADOW_FILE for password hashes longer than 3 characters"
    sed -i 's|^\([^:]*\):[^:]\{4,\}:\([^:]*:.*\)$|\1:<REDACTED>:\2|g' "$SHADOW_FILE"
    if [ $? -eq 0 ] && [ "$(sed 's|^\([^:]*\):[^:]\{4,\}:\([^:]*:.*\)$|\1:<REDACTED>:\2|g' "$SHADOW_FILE" | cmp - "$SHADOW_FILE" | wc -l)" -gt 0 ]; then
        echo "Redacted password hashes in $SHADOW_FILE"
    fi
fi

# Create new archive with redacted content
NEW_ARCHIVE="redacted_$(basename "$ARCHIVE")"
echo "Creating new archive: $NEW_ARCHIVE"
tar -czf "$NEW_ARCHIVE" -C "$TEMP_DIR" .

# Clean up temporary directory if not --no-cleanup
if [ "$CLEANUP" -eq 1 ]; then
    echo "Cleaning up temporary directory $TEMP_DIR"
    rm -rf "$TEMP_DIR"
else
    echo "Temporary directory $TEMP_DIR preserved (--no-cleanup)"
fi

echo "Redacted archive created: $NEW_ARCHIVE"
