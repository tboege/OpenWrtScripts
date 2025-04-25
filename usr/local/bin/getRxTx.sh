#!/bin/ash
HOST=$COLLECTD_HOSTNAME
INTERVAL=$COLLECTD_INTERVAL
[ -z "$INTERVAL" ] && INTERVAL=30
INTERVAL=$(awk -v i=$INTERVAL 'BEGIN{print int(i)}')
#echo $INTERVAL

while true; do
  RXTX=$(atftp  -g  -l /dev/stdout -r rxtx.txt 10.14.0.13)
  set -- $RXTX
  RX=$1
  TX=$2  # Output using PUTVAL
  UPTIME=$3
  echo "PUTVAL \"tv17/interface-wwan0/if_octets\" interval=$INTERVAL $EPOCHSECONDS:$RX:$TX"
  echo "PUTVAL \"tv17/uptime/uptime-process\" interval=$INTERVAL N:$UPTIME"
sleep $INTERVAL
done
