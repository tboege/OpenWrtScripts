#!/bin/ash
#Convert seconds-timestamp to YYYY/MM/DD... eg from dmesg (via stdin or file as first argument)
# Not completely accurate, which can be seen from:
#now=$(date +%Y-%m-%d\ %H:%M:%S);echo TBN $now > /dev/kmsg; dmesg| ./convert_dmesg.sh |tail;echo $now

# Logfile path from argument, or empty if none provided
LOGFILE="$1"

# Get boot time from uptime -s (e.g., "2025-03-26 16:29:52")
boot_time_str=$(uptime -s 2>/dev/null)
if [ -z "$boot_time_str" ]; then
    echo "Error: Failed to get boot time from 'uptime -s'." >&2
    exit 1
fi

# Convert boot time to seconds since epoch (assumes local time, e.g., CEST)
boot_time=$(date -u -d "$boot_time_str" +%s 2>/dev/null)
if [ -z "$boot_time" ]; then
    echo "Error: Failed to parse boot time '$boot_time_str'." >&2
    exit 1
fi

# Debug: Show boot time
echo "Debug: boot_time_str='$boot_time_str'" >&2
echo "Debug: boot_time=$boot_time (epoch seconds)" >&2

# Awk script to process log lines and output boot time
awk_script='
function format_time(seconds) {
    int_part = int(seconds)
    frac_part = sprintf("%06d", int((seconds - int_part) * 1000000))
    days_since_epoch = int(int_part / 86400)
    secs_remain = int_part % 86400
    year = 1970
    days_in_year = 365
    while (days_since_epoch >= days_in_year) {
        if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) {
            days_in_year = 366
        } else {
            days_in_year = 365
        }
        if (days_since_epoch >= days_in_year) {
            days_since_epoch -= days_in_year
            year++
        } else {
            break
        }
    }
    month_days = "31 28 31 30 31 30 31 31 30 31 30 31"
    if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) {
        month_days = "31 29 31 30 31 30 31 31 30 31 30 31"
    }
    split(month_days, days_arr, " ")
    month = 1
    day = days_since_epoch + 1
    while (day > days_arr[month]) {
        day -= days_arr[month]
        month++
    }
    hours = int(secs_remain / 3600)
    secs_remain %= 3600
    minutes = int(secs_remain / 60)
    seconds = secs_remain % 60
    return sprintf("%04d/%02d/%02d %02d:%02d:%02d.%s", year, month, day, hours, minutes, seconds, frac_part)
}

BEGIN {
    # Print boot time as the first line
    boot_time_str = format_time(boot_time + 0.0)
    print "Boot time: " boot_time_str
}

/^\[[[:space:]]{0,5}[0-9]+\.[0-9]+\]/ {
    # Extract timestamp, skipping opening [ and any whitespace
    start = match($0, /\[[[:space:]]{0,5}/) + RLENGTH
    end = index($0, "]")
    timestamp = substr($0, start, end - start)
    if (timestamp != "") {
        absolute_time = boot_time + timestamp
        formatted_time = format_time(absolute_time)
        print formatted_time " - " $0
    }
}
'

# Process input based on whether a logfile is provided
if [ -n "$LOGFILE" ]; then
    if [ ! -f "$LOGFILE" ]; then
        echo "Error: Logfile '$LOGFILE' not found." >&2
        echo "Usage: $0 [logfile_path] (or pipe log data via stdin)" >&2
        exit 1
    fi
    awk -v boot_time="$boot_time" "$awk_script" "$LOGFILE"
else
    awk -v boot_time="$boot_time" "$awk_script"
fi