#!/bin/bash -ex

# restore default cups config in case user does not have any
if [ ! -f /etc/cups/cupsd.conf ]; then
    cp -rpn /etc/cups-bak/* /etc/cups/
fi

# Check if settings.txt exists in mounted volume
if [ ! -f /etc/cups/process_labels/settings.txt ]; then
    # Copy settings.txt from the backup directory if it doesn't exist
    cp -f /etc/settings-bak/settings.txt /etc/cups/process_labels/settings.txt
fi

if [ ! -d "/output" ]; then
    mkdir -p /output
fi
# Set permissions to 766
chmod 766 /output

exec /root/start-cups.sh "$@"
