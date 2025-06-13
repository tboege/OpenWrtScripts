#!/bin/ash
# setup phone
# if [ ! -f /etc/config/net-monitor ] ; then touch /etc/config/net-monitor; fi
# uci set net-monitor.sms=config
# uci set net-monitor.sms.phoneno="123456789"
# uci set net-monitor.sms.interface="lte"
# uci commit net-monitor

# Configuration
LTE_INTERFACE=$(uci get net-monitor.sms.interface 2>/dev/null)
LOG_TAG=net-mon
CHECK_INET_HOSTS="8.8.8.8 8.8.4.4 1.1.1.1 9.9.9.9 4.2.2.2"  # Internet hosts to check
CHECK_INTERVAL=30  # 30 seconds
MAX_ERRORS=5  # Threshold for errors before LTE action
MAX_INET_PERSISTENT_ERRORS=120  # Threshold for persistent internet errors before reboot
HOURLY_CHECK_THRESHOLD=$((3600 / CHECK_INTERVAL))  # Number of checks in 1 hour (3600 seconds)

# Initialize error counters and globals
inet_error_count=0
inet_persistent_error_count=0
success_check_count=0  # Counter for successful checks
SMS_TTY=""  # TTY device for sms_tool
LAST_SMS_FAILED=0  # Track if last SMS send failed (0=success, 1=failure)

# Function to log messages (calls logger and echoes to console)
log() {
    logger -t "$LOG_TAG" "$1"
    local logmsg="$(date -Iseconds) $1"
    echo "$logmsg" >> /tmp/net-monitor.log
    if [ -t 1 ]; then # running in terminal
        echo "$logmsg"
    fi
}

# Function to run a command with a timeout
run_with_timeout() {
    local timeout="$1"
    local cmd="$2"
    
    # Run command in background and store output
    eval "$cmd" > /tmp/sms_tool_output 2>/dev/null &
    pid=$!
    # Check every second for timeout seconds
    seconds=0
    while [ $seconds -lt $timeout ]; do
        sleep 1
        seconds=$((seconds + 1))
        if ! kill -0 $pid 2>/dev/null; then
            # Process finished early
            wait $pid 2>/dev/null
            output=$(cat /tmp/sms_tool_output 2>/dev/null)
            rm -f /tmp/sms_tool_output
            echo "$output"
            return 0
        fi
    done
    # Timeout reached, kill process
    if kill -0 $pid 2>/dev/null; then
        kill $pid 2>/dev/null
        wait $pid 2>/dev/null
    fi
    output=$(cat /tmp/sms_tool_output 2>/dev/null)
    rm -f /tmp/sms_tool_output
    echo "$output"
    return 1
}

# Function to find responding TTY for sms_tool
find_sms_tty() {
    log "Detecting SMS_TTY"
    for tty in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
        log "Try $tty"
        output=$(run_with_timeout 7 "sms_tool -d $tty status")
        # Check if output contains "Storage type: ME"
        if echo "$output" | grep -q "Storage type: ME"; then
            SMS_TTY="$tty"
            log "Found responding SMS TTY: $SMS_TTY"
            return 0
        fi
    done
    log "No responding SMS TTY found"
    return 1
}

# Function to try sending an SMS
try_send_sms() {
    local message="$1"
	log "Sending SMS to $PHONE_NO: $message"
	output=$(run_with_timeout 5 "sms_tool -d $SMS_TTY send $PHONE_NO \"$message\"")
	# Check if output contains "sms sent sucessfully"
	if echo "$output" | grep -q "sms sent sucessfully"; then
		log "SMS sent successfully to $PHONE_NO: $output"
		LAST_SMS_FAILED=0
		return 0
	else
		log "Failed to send SMS to $PHONE_NO: $output"
		LAST_SMS_FAILED=1
		return 1
	fi
}    

# Function to send SMS (queues the message)
send_sms() {
    local message="$1"
    # Queue the message
    echo "$message" >> /tmp/sms_queue
    log "Queued SMS: $message"
	process_sms_queue
    return 0
}

# Function to process queued SMS messages
process_sms_queue() {
    # Check if queue file exists and is non-empty
    if [ -f /tmp/sms_queue ] && [ -s /tmp/sms_queue ]; then
        # Read the first message
        local message=$(head -n 1 /tmp/sms_queue)
        log "Processing queued SMS: $message"
        # Attempt to send
		# Reevaluate SMS_TTY only if empty or last send failed
		PHONE_NO=$(uci get net-monitor.sms.phoneno 2>/dev/null)
		if [ -z "$PHONE_NO" ]; then
			log "Failed to send SMS: Phone number not configured in UCI (net-monitor.sms.phoneno)"
			LAST_SMS_FAILED=1
			return 1
		fi
		if [ -z "$SMS_TTY" ] || [ "$LAST_SMS_FAILED" -eq 1 ]; then
			find_sms_tty
		fi
		if [ -z "$SMS_TTY" ]; then
			log "Cannot send SMS: No responding TTY configured ($message)"
			LAST_SMS_FAILED=1
			return 1
		fi
        if try_send_sms "$message"; then
            # Remove the first line from the queue
            sed -i '1d' /tmp/sms_queue
            log "Removed sent message from queue"
            # If queue is empty, remove the file
            if [ ! -s /tmp/sms_queue ]; then
                rm -f /tmp/sms_queue
            fi
        else
            log "Failed to send queued SMS, keeping in queue"
        fi
    fi
}

# Function to check if a host is reachable
ping_host() {
    ping -c 1 -W 2 "$1" >/dev/null 2>&1
}

# Function to check internet connectivity and rotate hosts
check_internet() {
    local internet_up=false
    local successful_hosts=""
    local failed_hosts=""
    local not_checked_hosts=""
    
    for host in $CHECK_INET_HOSTS; do
        if [ "$internet_up" = true ]; then
            # If internet is already up, add host to not_checked_hosts
            if [ -z "$not_checked_hosts" ]; then
                not_checked_hosts="$host"
            else
                not_checked_hosts="$not_checked_hosts $host"
            fi
        else
            # Ping host if internet is not yet up
            if ping_host "$host"; then
                internet_up=true
                if [ -z "$successful_hosts" ]; then
                    successful_hosts="$host"
                else
                    successful_hosts="$successful_hosts $host"
                fi
                # log "Internet host $host is reachable"
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

    # Update CHECK_INET_HOSTS only if there are failed hosts
    if [ -n "$failed_hosts" ] && [ "$internet_up" = true ]; then
        CHECK_INET_HOSTS="$successful_hosts $not_checked_hosts $failed_hosts"
        log "Updated CHECK_INET_HOSTS: $CHECK_INET_HOSTS"
    fi

    if [ "$internet_up" = true ]; then
        inet_error_count=0
        inet_persistent_error_count=0  # Reset persistent counter on internet success
        return 0
    else
        inet_error_count=$((inet_error_count + 1))
        inet_persistent_error_count=$((inet_persistent_error_count + 1))
        log "Internet is down ($inet_error_count/$MAX_ERRORS failures, persistent: $inet_persistent_error_count/$MAX_INET_PERSISTENT_ERRORS)"
        send_sms "$(date -Iseconds) Internet is down ($inet_error_count/$MAX_ERRORS failures, persistent: $inet_persistent_error_count/$MAX_INET_PERSISTENT_ERRORS)"
        return 1
    fi
}

# Function to bring up LTE interface
bring_up_lte() {
    log "Internet down after $inet_error_count failures, attempting to bring up LTE..."
    /sbin/ifup "$LTE_INTERFACE" >/dev/null 2>&1
    inet_error_count=0  # Reset internet error counter after LTE attempt
    # Check if internet is restored after LTE bring-up
    if check_internet; then
        log "LTE bring-up restored internet connectivity"
    else
        log "LTE bring-up failed to restore internet connectivity"
    fi
}

# Function to reboot router
reboot_router() {
    log "Persistent internet failure after $inet_persistent_error_count/$MAX_INET_PERSISTENT_ERRORS failures, rebooting router..."
    /sbin/reboot
}

# Main function
main() {
    if [ -t 1 ]; then
        log "Starting (running in terminal)"
    else
        log "Starting (not running in terminal)"
    fi
    # Send SMS at startup
    if [ -z "$LTE_INTERFACE" ]; then
		send_sms "$(date -Iseconds) Network monitor started Error: Interface number not configured in UCI (uci get net-monitor.sms.interface)"
		LAST_SMS_FAILED=1
		exit 1
    else
        send_sms "$(date -Iseconds) Network monitor started"
	fi
	log "Monitoring interface $LTE_INTERFACE"		

    # Main loop
    while true; do
        # Check internet
        if check_internet; then
            success_check_count=$((success_check_count + 1))
            # Check if success count exceeds hourly threshold
            if [ "$success_check_count" -gt "$HOURLY_CHECK_THRESHOLD" ]; then
                log "Internet has been up for at least an hour ($success_check_count checks performed)"
                success_check_count=0  # Reset counter after logging
            fi
        else
            success_check_count=0  # Reset counter on internet failure
            # Internet is down, consider bringing up LTE first
            if [ "$inet_error_count" -ge "$MAX_ERRORS" ]; then
                bring_up_lte
            # Then check persistent errors for reboot
            elif [ "$inet_persistent_error_count" -gt "$MAX_INET_PERSISTENT_ERRORS" ]; then
                reboot_router
            fi
        fi
        # Process queued SMS messages
        process_sms_queue
        sleep "$CHECK_INTERVAL"
    done
}

# Call main function
main