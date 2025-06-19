#!/bin/ash
# Network monitoring script for internet connectivity with SMS notifications
# Example of setup of config for phoneno and interface
# if [ ! -f /etc/config/net-monitor ] ; then touch /etc/config/net-monitor; fi
# uci set net-monitor.sms=config
# uci set net-monitor.sms.phoneno="123456789"
# uci set net-monitor.sms.interface="lte"
# uci commit net-monitor
# Cleanup function for graceful shutdown
cleanup() {
    rm -f $TEMP_OUT $SMS_QUEUE
    log "Script terminated, cleaned up temporary files"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Ensure UCI configuration exists
if [ ! -f /etc/config/net-monitor ] || [ -z "$(uci get net-monitor.sms.phoneno 2>/dev/null)" ] || [ -z "$(uci get net-monitor.sms.interface 2>/dev/null)" ]; then
    log "Error: UCI configuration missing or incomplete. Please set net-monitor.sms.phoneno and net-monitor.sms.interface."
    exit 1
fi

# Configuration
NET_IF=$(uci get net-monitor.sms.interface 2>/dev/null)
LOG_PREFIX=net-mon
LOG_PATH="/tmp/net-monitor.log"
PING_HOSTS="8.8.8.8 8.8.4.4 1.1.1.1 9.9.9.9 4.2.2.2"
PING_INTERVAL=30
MAX_IF_ERRORS=5
MAX_TOTAL_ERRORS=120
MAX_LOG_SIZE=10485760
SMS_STAT_TIMEOUT=5
SMS_TX_TIMEOUT=5
MIN_REBOOT_WAIT=$((HOUR_SECS * 1))
MAX_SMS_QUEUE=100
MAX_SMS_FAILS=3
SMS_QUEUE="/tmp/sms_queue.$$"
TEMP_OUT="/tmp/sms_tool_output.$$"
# Constants
HOUR_SECS=3600
MINUTE_SECS=60

# Initialize globals
if_error_count=0
total_error_count=0
up_start=""
up_start_readable=""
last_log=0
last_reboot=0
sms_fail_count=0
SMS_PORT=""
sms_failed=0
down_start=""

# Function to log messages
log() {
    local message="$1"
    logger -t "$LOG_PREFIX" "$message"
    local logmsg="$(date +"%Y-%m-%d %H:%M:%S") $message"
    local log_file="$LOG_PATH"

    if [ -f "$log_file" ]; then
        local file_size=$(wc -c < "$log_file")
        if [ "$file_size" -gt "$MAX_LOG_SIZE" ]; then
            local line_count=$(wc -l < "$log_file")
            local keep_lines=$((line_count / 2))
            tail -n "$keep_lines" "$log_file" > "$log_file.tmp" && mv "$log_file.tmp" "$log_file"
        fi
    fi

    echo "$logmsg" >> "$log_file"
    [ -t 1 ] && echo "$logmsg"
}

# Function to calculate uptime
get_uptime() {
    local start_time="$1"
    local current_time=$(date +%s)
    [ -z "$start_time" ] && { echo "Unknown"; return 1; }
    local uptime_secs=$((current_time - start_time))
    local hours=$((uptime_secs / HOUR_SECS))
    local minutes=$(( (uptime_secs % HOUR_SECS) / MINUTE_SECS ))
    local seconds=$((uptime_secs % MINUTE_SECS))
    printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
}

# Function to run a command with timeout
run_timed() {
    local timeout="$1"
    local cmd="$2"

    eval "$cmd" > "$TEMP_OUT" 2>&1 &
    local pid=$!
    local seconds=0

    while [ $seconds -lt $timeout ]; do
        sleep 1
        seconds=$((seconds + 1))
        if ! kill -0 $pid 2>/dev/null; then
            wait $pid
            local exit_code=$?
            output=$(cat "$TEMP_OUT" 2>/dev/null)
            rm -f "$TEMP_OUT"
            echo "$output"
            return $exit_code
        fi
    done

    kill -0 $pid 2>/dev/null && kill $pid 2>/dev/null
    wait $pid 2>/dev/null
    output=$(cat "$TEMP_OUT" 2>/dev/null)
    rm -f "$TEMP_OUT"
    echo "$output"
    return 1
}

# Function to find SMS TTY
find_sms_port() {
    log "Detecting SMS_PORT"
    for tty in /dev/ttyUSB[0-3] /dev/ttyACM[0-3] /dev/ttyS[0-3]; do
        log "Try $tty"
        output=$(run_timed "$SMS_STAT_TIMEOUT" "sms_tool -d $tty status")
        if echo "$output" | grep -q "Storage type: ME"; then
            SMS_PORT="$tty"
            log "Found responding SMS TTY: $SMS_PORT"
            return 0
        fi
    done
    log "No responding SMS TTY found"
    return 1
}

# Function to try sending SMS
send_sms_try() {
    local message="$1"
    log "Sending SMS to $SMS_NUMBER: $message"
    output=$(run_timed "$SMS_TX_TIMEOUT" "sms_tool -d $SMS_PORT send $SMS_NUMBER \"$message\"")
    if echo "$output" | grep -q "sms sent sucessfully"; then
        log "SMS sent successfully to $SMS_NUMBER: $output"
        sms_failed=0
        return 0
    else
        log "Failed to send SMS to $SMS_NUMBER: $output"
        sms_failed=1
        return 1
    fi
}

# Function to queue SMS
queue_sms() {
    local message="$1"
    echo "$message" >> "$SMS_QUEUE"
    log "Queued SMS: $message"
    if [ -f "$SMS_QUEUE" ]; then
        local line_count=$(wc -l < "$SMS_QUEUE")
        if [ "$line_count" -gt "$MAX_SMS_QUEUE" ]; then
            tail -n "$MAX_SMS_QUEUE" "$SMS_QUEUE" > "$SMS_QUEUE.tmp" && mv "$SMS_QUEUE.tmp" "$SMS_QUEUE"
            log "SMS queue trimmed to $MAX_SMS_QUEUE messages"
        fi
    fi
    process_queue
    return 0
}

# Function to process SMS queue
process_queue() {
    [ ! -f "$SMS_QUEUE" ] || [ ! -s "$SMS_QUEUE" ] && return 0
    local message=$(head -n 1 "$SMS_QUEUE")
    log "Processing queued SMS: $message"

    SMS_NUMBER=$(uci get net-monitor.sms.phoneno 2>/dev/null)
    if [ -z "$SMS_NUMBER" ] || ! echo "$SMS_NUMBER" | grep -qE '^45[0-9+]{8}$'; then
        log "Failed to send SMS: Invalid or missing phone number"
        sms_failed=1
        return 1
    fi

    [ -z "$SMS_PORT" ] || [ "$sms_failed" -eq 1 ] && find_sms_port
    if [ -z "$SMS_PORT" ]; then
        log "Cannot send SMS: No responding TTY configured ($message)"
        sms_failed=1
        return 1
    fi

    if send_sms_try "$message"; then
        sed -i '1d' "$SMS_QUEUE"
        log "Removed sent message from queue"
        sms_fail_count=0
    else
        log "Failed to send queued SMS, keeping in queue"
        sms_fail_count=$((sms_fail_count + 1))
        [ "$sms_fail_count" -ge "$MAX_SMS_FAILS" ] && { SMS_PORT=""; sms_fail_count=0; }
    fi
}

# Function to ping host
ping_host() {
    ping -c 1 -W 2 "$1" >/dev/null 2>&1
}

# Function to check internet
check_net() {
    local internet_up=false
    local successful_hosts=""
    local failed_hosts=""
    local not_checked_hosts=""

    for host in $PING_HOSTS; do
        if [ "$internet_up" = true ]; then
            if [ -z "$not_checked_hosts" ]; then
                not_checked_hosts="$host"
            else
                not_checked_hosts="$not_checked_hosts $host"
            fi
        else
            if ping_host "$host"; then
                internet_up=true
                if [ -z "$successful_hosts" ]; then
                    successful_hosts="$host"
                else
                    successful_hosts="$successful_hosts $host"
                fi
            else
                if [ -z "$failed_hosts" ]; then
                    failed_hosts="$host"
                else
                    failed_hosts="$failed_hosts $host"
                fi
                log "Internet host $host is not reachable"
            fi
        fi
    done

    if [ -n "$failed_hosts" ] && [ "$internet_up" = true ]; then
        PING_HOSTS="$successful_hosts $not_checked_hosts $failed_hosts"
        log "Updated PING_HOSTS: $PING_HOSTS"
    fi

    if [ "$internet_up" = true ]; then
        if_error_count=0
        total_error_count=0
        if [ -z "$up_start" ]; then
            up_start=$(date +%s)
            up_start_readable=$(date +"%Y-%m-%d %H:%M:%S")
            log "Internet is up, setting up_start to $up_start_readable"
        fi
                
        return 0
    else
        if_error_count=$((if_error_count + 1))
        total_error_count=$((total_error_count + 1))
        log "Internet is down ($if_error_count/$MAX_IF_ERRORS failures, persistent: $total_error_count/$MAX_TOTAL_ERRORS)"
        up_start=""
        up_start_readable=""
        return 1
    fi
}

# Function to bring up LTE interface
restore_net() {
    log "Internet down after $if_error_count failures, attempting to bring up LTE..."
    queue_sms "$(date +"%Y-%m-%d %H:%M:%S") Internet down after $if_error_count failures, attempting to bring up LTE..."
    /sbin/ifup "$NET_IF" > /dev/null 2>&1
    if_error_count=0
    if check_net; then
        log "LTE bring-up restored internet connectivity"
    else
        log "LTE bring-up failed to #restore internet connectivity"
    fi
}

# Function to reboot router
reboot() {
    local current_time=$(date +%s)
    if [ $((current_time - last_reboot)) -lt "$MIN_REBOOT_WAIT" ]; then
        log "Reboot requested but skipped (within $MIN_REBOOT_WAIT seconds of last reboot)"
        return
    fi
    log "Persistent internet failure after $total_error_count/$MAX_TOTAL_ERRORS failures, rebooting router in 10 seconds..."
    queue_sms "$(date +"%Y-%m-%d %H:%M:%S") Rebooting router due to persistent internet failure"
    sleep 10
    last_reboot=$current_time
    /sbin/reboot
}

# Function to initialize monitoring
init_monitor() {
    [ -t 1 ] && log "Starting (running in terminal) PID $$" || log "Starting (not running in terminal) PID $$"
    if [ -z "$NET_IF" ]; then
        queue_sms "$(date +"%Y-%m-%d %H:%M:%S") Network monitor started Error: Interface number not configured in UCI"
        sms_failed=1
        exit 1
    fi
    log "Monitoring interface $NET_IF"
}

# Function to log hourly uptime
log_uptime() {
    local current_time=$(date +%s)
    if [ -n "$up_start" ] && { [ "$last_log" -eq 0 ] || [ $((current_time - last_log)) -ge $HOUR_SECS ]; }; then
        local uptime=$(get_uptime "$up_start")
        log "Internet has been up $uptime since $up_start_readable"
        last_log=$current_time
    fi
}

# Function to handle internet status
handle_net_status() {
    if check_net; then
        [ "$1" = "SENDSMS" ] && queue_sms "$(date +"%Y-%m-%d %H:%M:%S") Network monitor started - internet is UP"
        if [ -n "$down_start" ]; then
            log "Internet connectivity restored."
            queue_sms "$(date +"%Y-%m-%d %H:%M:%S") Internet restored - down since $down_start"
            down_start=""
        else
            log_uptime
        fi
    else
        [ "$1" = "SENDSMS" ] && queue_sms "$(date +"%Y-%m-%d %H:%M:%S") Network monitor started - internet is DOWN"
        [ -z "$down_start" ] && down_start=$(date +"%Y-%m-%d %H:%M:%S")
        [ "$if_error_count" -ge "$MAX_IF_ERRORS" ] && restore_net
        [ "$total_error_count" -gt "$MAX_TOTAL_ERRORS" ] && reboot
    fi
}

# Main function
main() {
    init_monitor
    sleep 60
    handle_net_status "SENDSMS"
    while true; do
        sleep "$PING_INTERVAL"
        handle_net_status
        process_queue
    done
}

# Call main function
main