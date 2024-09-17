FROM drpsychick/airprint-bridge:latest

# Create the necessary directory
RUN mkdir -p /etc/cups/process_labels

# Copy configuration and PPD files
COPY /dist/printers.conf /etc/cups/
COPY /dist/Label_Printer.ppd /etc/cups/ppd/
COPY /dist/dummy.ppd /etc/cups/ppd/

# Copy settings file
RUN mkdir -p /etc/settings-bak
COPY /settings.txt /etc/settings-bak

# Copy the split ELF file chunks
COPY /dist/process_labels_split_part* /etc/cups/process_labels/

# Recombine the split ELF file chunks
RUN cat /etc/cups/process_labels/process_labels_split_part* > /etc/cups/process_labels/process_labels.elf

# Remove chunk files
RUN rm /etc/cups/process_labels/process_labels_split_part*

# Copy the backend script
COPY /dist/label-backend.sh /usr/lib/cups/backend/label-backend

# Copy the contents of /etc/cups/ to /etc/cups-bak/
RUN mkdir -p /etc/cups-bak && cp -r /etc/cups/* /etc/cups-bak/

# Set ownership and permissions
RUN chown root:root /usr/lib/cups/backend/label-backend && chmod 755 /usr/lib/cups/backend/label-backend
RUN chown root:root /etc/cups/process_labels/process_labels.elf && chmod 755 /etc/cups/process_labels/process_labels.elf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
