FROM drpsychick/airprint-bridge:latest

# Create the necessary directory
RUN mkdir -p /etc/cups/process_labels

# Copy configuration and PPD files
COPY /dist/printers.conf /etc/cups/
COPY /dist/Label_Printer.ppd /etc/cups/ppd/

# Copy the executable with its extension
COPY /dist/process_labels.elf /etc/cups/process_labels/process_labels.elf

# Copy the backend script
COPY label-backend.sh /usr/lib/cups/backend/label-backend

# Set ownership and permissions
RUN chown root:root /usr/lib/cups/backend/label-backend && chmod 755 /usr/lib/cups/backend/label-backend
