# --- Build Stage ---
# Use a Python base image suitable for building
FROM python:3.9-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Add any necessary system dependencies for pymupdf, opencv-python-headless etc.
    libglib2.0-0 libsm6 libxrender1 libfontconfig1 libice6 \
    # Add binutils as required by PyInstaller
    binutils \
    # Add build-essential for C/C++ compilers needed by some pip packages
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory inside the builder stage
WORKDIR /app

# Copy necessary source files for the build
# Assuming process_labels.py and requirements.txt are at the root of the repo
COPY process_labels.py .
# Ensure this requirements.txt contains pyinstaller AND your script's dependencies
COPY requirements.txt .

# Install Python dependencies including PyInstaller
RUN pip install --no-cache-dir -r requirements.txt

# Build the executable using PyInstaller
# This command will run for each architecture targeted by buildx
RUN pyinstaller --onefile process_labels.py

# --- Runtime Stage ---
# Use your desired base image
FROM drpsychick/airprint-bridge:latest

# Create necessary directories
RUN mkdir -p /usr/lib/process_labels /etc/settings-bak /etc/cups-bak /etc/cups/ppd /usr/lib/cups/backend

# Copy configuration and PPD files from the source context /dist/ folder
COPY /dist/printers.conf /etc/cups/
COPY /dist/ppd/ /etc/cups/ppd/
COPY /dist/custompslabelfilter /etc/cups/

# Copy settings file from the source context root folder
COPY /process_labels_settings.txt /etc/settings-bak/

# Copy the backend script from the source context /dist/ folder
COPY /dist/label-backend.sh /usr/lib/cups/backend/label-backend

# Copy the built executable from the builder stage
# The 'process_labels.elf' name is kept for consistency with your original script/entrypoint
COPY --from=builder /app/dist/process_labels /usr/lib/process_labels/process_labels.elf

# Copy the contents of /etc/cups/ to /etc/cups-bak/ (after copying initial config)
RUN cp -r /etc/cups/* /etc/cups-bak/

# Set ownership and permissions
RUN chown root:root /usr/lib/cups/backend/label-backend && chmod 0500 /usr/lib/cups/backend/label-backend
RUN chown root:root /usr/lib/process_labels/process_labels.elf && chmod 755 /usr/lib/process_labels/process_labels.elf
RUN chown root:root /etc/cups/custompslabelfilter && chmod 755 /etc/cups/custompslabelfilter

# Entrypoint setup
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
