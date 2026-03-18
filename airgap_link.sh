#!/bin/bash
INTERFACE="ens4"
IP_ADDR="192.168.1.45/24"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]    $1" | tee -a "${LOG_FILE:-/dev/null}"
}

case "$1" in
  open)
    log_msg "Opening Air-Gap..."
    sudo ip link set $INTERFACE up
    sudo ip addr add $IP_ADDR dev $INTERFACE
    # Wait for the Realtek chip to negotiate with the switch
    sleep 2
    log_msg "Data NIC is now UP at $IP_ADDR"
    ;;
  close)
    log_msg "Closing Air-Gap..."
    sudo ip addr flush dev $INTERFACE
    sudo ip link set $INTERFACE down
    log_msg "Data NIC is now physically DOWN."
    ;;
  *)
    echo "Usage: $0 {open|close}"
    exit 1
esac