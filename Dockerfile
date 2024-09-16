FROM drpsychick/airprint-bridge:latest

# Create the necessary directory
RUN mkdir -p /etc/cups/process_labels

# Copy configuration and PPD files
COPY /dist/printers.conf /etc/cups/
COPY /dist/Label_Printer.ppd /etc/cups/ppd/
COPY /dist/dummy.ppd /etc/cups/ppd/

# Copy the split ELF file chunks
COPY /dist/process_labels_split_part* /etc/cups/process_labels/

# Recombine the split ELF file chunks
RUN cat /etc/cups/process_labels/process_labels_split_part* > /etc/cups/process_labels/process_labels.elf

# Remove chunk files
RUN rm /etc/cups/process_labels/process_labels_split_part*

# Copy the backend script
COPY label-backend.sh /usr/lib/cups/backend/label-backend

# Set ownership and permissions
RUN chown root:root /usr/lib/cups/backend/label-backend && chmod 755 /usr/lib/cups/backend/label-backend

# Set default environment variables
ENV output_path="/tmp/label_print_job.pdf"
ENV dpi=600
ENV error_margin_percent=20
ENV set_margin=0.1
ENV ant_threshold=0.2
