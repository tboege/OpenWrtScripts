#!/bin/ash

# Configuration
LTE_INTERFACE=lte
LOG_TAG=net-mon
CHECK_INET_HOSTS="8.8.8.8 8.8.4.4 1.1.1.1 9.9.9.9 4.2.2.2"  # Internet hosts to check
CHECK_INTERVAL=30  # 30 seconds
MAX_ERRORS=5  # Threshold for errors before LTE action
MAX_INET_PERSISTENT_ERRORS=120  # Threshold for persistent internet errors before reboot

# Initialize error counters
inet_error_count=0
inet_persistent_error_count=0

# Function to log messages (calls logger and echoes to console)
log() {
    logger -t "$LOG_TAG" "$1"
    echo "$1"
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

# Main loop
while true; do
    # Check internet
    if check_internet; then
        : # Internet is up, do nothing
    else
        # Internet is down, consider bringing up LTE first
        if [ "$inet_error_count" -ge "$MAX_ERRORS" ]; then
            bring_up_lte
        # Then check persistent errors for reboot
        elif [ "$inet_persistent_error_count" -gt "$MAX_INET_PERSISTENT_ERRORS" ]; then
            reboot_router
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
