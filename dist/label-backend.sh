#!/bin/bash

# Global variable for the log buffer.
# Messages will be stored here if the log file is not yet writable.
log_buffer=""

# job_dir will store the path to the temporary job directory
job_dir=""
# pdf_path will store the path to the intermediate PDF file
pdf_path=""
# output_path will store the path to the final output PDF file
output_path=""

# Function to write to the output log
write_to_output_log() {
    local message=$1
    local formatted_message="JobCrop: $message"

    # Always echo the message to standard error for CUPS logging
    echo "$formatted_message" >&2

    # Check if the job_dir is set and the process log file exists and is writable
    if [ -n "$job_dir" ] && [ -f "$job_dir/process_log.txt" ] && [ -w "$job_dir/process_log.txt" ]; then
        # If the log file is writable:
        if [ -n "$log_buffer" ]; then
            # If there's content in the buffer, append the current message to it
            # Add newline BEFORE the new message when appending to buffer
            log_buffer+="$'\n'$formatted_message"
            # Write the entire buffer to the log file using -n to avoid extra newline
            echo -n "$log_buffer" >> "$job_dir/process_log.txt"
            # Clear the buffer after writing
            log_buffer=""
        else
            # If the buffer is empty, write the current message directly to the log file
            # No -n here, as we want a newline after this single message
            echo "$formatted_message" >> "$job_dir/process_log.txt"
        fi
    else
        # If the log file is not writable, append the message to the buffer
        if [ -n "$log_buffer" ]; then
             # Add newline BEFORE the new message when appending to buffer
             log_buffer+="$'\n'$formatted_message"
        else
             # First message in buffer, no leading newline needed
             log_buffer+="$formatted_message"
        fi
    fi
}

# Function to cancel the CUPS job
cancel_cups_job() {
    local reason="$1" # Optional message for the log indicating why cancel was called
    local job_id="$CUPS_JOBID"

    if [ -n "$job_id" ]; then
        write_to_output_log "Attempting to cancel CUPS job $job_id. Reason: ${reason:-Unknown}"

        # Attempt to cancel the job
        if cancel "$job_id"; then
             write_to_output_log "Cancelled job $job_id successfully."
        else
             write_to_output_log "Warning: Failed to cancel job $job_id."
        fi
    else
        write_to_output_log "CUPS_JOBID environment variable not set. Cannot cancel job. Reason: ${reason:-Unknown}"
    fi
}


# Function to call the ELF executable for cropping
Crop_PDF() {
    # This function now only calls the ELF with the necessary parameters
    local current_pdf_path="$1" # Path to the PDF generated from PostScript
    local dpi="$2"
    local set_margin="$3"
    local current_output_path="$4" # Path where the ELF should save the processed PDF

    write_to_output_log "Calling process_labels.elf \"$current_pdf_path\" \"$dpi\" \"$set_margin\" \"$current_output_path\""
    # Call the ELF executable with the updated parameters (error_margin_percent and ant_threshold removed)
    /etc/cups/process_labels/process_labels.elf "$current_pdf_path" "$dpi" "$set_margin" "$current_output_path"
    # Check the exit status of the ELF
    if [ $? -ne 0 ]; then
        write_to_output_log "Error: process_labels.elf failed."
        return 1 # Indicate failure
    fi
    return 0 # Indicate success
}

main() {
    # Delete old JobX folders (older than 1 day)
    # Use write_to_output_log - messages will be buffered until log file is created
    write_to_output_log "Deleting old job directories..."
    find /tmp -maxdepth 1 -type d -name 'Job[0-9]*' -mtime +1 -exec rm -rf {} +

    # Create a new JobX folder
    # Use write_to_output_log - messages will be buffered until log file is created
    write_to_output_log "Creating new job directory..."
    for i in {1..1000}; do
        if [ ! -d "/tmp/Job$i" ]; then
            job_dir="/tmp/Job$i"
            mkdir "$job_dir"
            # Check if directory creation was successful
            if [ $? -ne 0 ]; then
                write_to_output_log "Error: Failed to create job directory $job_dir."
                # Call cancel_cups_job before exiting on error
                cancel_cups_job "Failed to create job directory"
                exit 1
            fi
            break
        fi
    done

    # Check if job_dir was successfully set after the loop
    if [ -z "$job_dir" ]; then
        write_to_output_log "Error: Failed to create a unique job directory."
        # Call cancel_cups_job before exiting on error
        cancel_cups_job "Failed to find unique job directory"
        exit 1
    fi

    # Create the process log file inside the newly created job directory
    # Check if log file creation was successful immediately, before trying to log to it
    if ! touch "$job_dir/process_log.txt"; then
        write_to_output_log "Error: Failed to create process log file $job_dir/process_log.txt."
        # Call cancel_cups_job before exiting on error, log will go to stderr and buffer
        cancel_cups_job "Failed to create process log file"
        exit 1
    fi
    # Now that the log file exists, subsequent calls to write_to_output_log
    # will write the buffer content and then new messages directly.
    # The function itself handles checking the buffer state and flushing.
    write_to_output_log "Job directory created at $job_dir" # This message and buffered ones will now be written
    write_to_output_log "Log file created at $job_dir/process_log.txt"


    # Define paths for intermediate and output files within the job directory
    pdf_path="$job_dir/label_input.pdf"
    output_path="$job_dir/label_print_job.pdf"


    # Read input data from stdin (the PostScript data from CUPS)
    write_to_output_log "Reading input PostScript data..."
    local input_data
    input_data=$(cat)
    # Check if input data was read successfully. If not, exit immediately.
    if [ -z "$input_data" ]; then
         write_to_output_log "Error: No input PostScript data received."
         # Call cancel_cups_job before exiting on error
         cancel_cups_job "No input PostScript data"
         exit 1
    fi
    write_to_output_log "Input PostScript data read successfully."


    # Save input_data to job_dir/input_postscript.ps for debugging/archiving
    write_to_output_log "Saving input PostScript to $job_dir/input_postscript.ps"
    echo "$input_data" > "$job_dir/input_postscript.ps"
    # Check if saving the input data was successful
    if [ $? -ne 0 ]; then
        write_to_output_log "Error: Failed to save input PostScript data."
        # Call cancel_cups_job before exiting on error
        cancel_cups_job "Failed to save input PostScript"
        exit 1
    fi

    # --- Convert PostScript to PDF ---
    # Set environment variables required by pstopdffx
    export DEVICE_URI="file:///dev/null"
    # Store the original PRINTER variable before exporting our dummy value
    local original_printer="$PRINTER"
    export PRINTER="Label_Printer" # Dummy printer name for the filter
    export PPD="/etc/cups/ppd/dummy.ppd" # Dummy PPD file

    write_to_output_log "Converting PostScript to PDF: $pdf_path"
    # Pipe the input PostScript data to the pstopdffx filter
    echo "$input_data" | /usr/lib/cups/filter/pstopdffx 1 1 1 1 > "$pdf_path"
    # Check if PDF conversion was successful
    if [ $? -ne 0 ]; then
        write_to_output_log "Error: PostScript to PDF conversion failed."
        # Call cancel_cups_job before exiting on error
        cancel_cups_job "PostScript to PDF conversion failed"
        exit 1
    fi
    write_to_output_log "PostScript converted to PDF successfully."

    # --- Get settings from settings.txt ---
    local settings_file="/etc/cups/process_labels/settings.txt"
    local dpi # Declare variables locally
    local set_margin
    local retention_period
    local direct_label_printer
    local test_mode # Also declare test_mode here

    write_to_output_log "Checking for settings file: $settings_file"
    if [ -f "$settings_file" ]; then
        write_to_output_log "Getting values from $settings_file"
        # Read DPI, Set_Margin, Retention_Period, Direct_Label_Printer, and TestMode
        # Use parameter expansion with default values if grep fails or value is empty
        dpi=$(grep -E '^dpi=' "$settings_file" | awk -F '=' '{print $2}' | xargs)
        dpi=${dpi:-600} # Default to 600 if not found or empty

        set_margin=$(grep -E '^set_margin=' "$settings_file" | awk -F '=' '{print $2}' | xargs)
        set_margin=${set_margin:-0.1} # Default to 0.1 if not found or empty

        retention_period=$(grep -E '^Retention_Period=' "$settings_file" | awk -F '=' '{print $2}' | xargs)
        retention_period=${retention_period:-90} # Default to 90 if not found or empty

        direct_label_printer=$(grep -E '^Direct_Label_Printer=' "$settings_file" | awk -F '=' '{print $2}' | xargs)
        # direct_label_printer can be empty if not set

        test_mode=$(grep -E '^TestMode=' "$settings_file" | awk -F '=' '{print $2}' | xargs)
        test_mode=${test_mode:-"FALSE"} # Default to FALSE if not found or empty

        write_to_output_log "Settings loaded: DPI=$dpi, Set_Margin=$set_margin, Retention_Period=$retention_period, Direct_Label_Printer=$direct_label_printer, TestMode=$test_mode"
    else
        # Use default values if settings.txt doesn't exist
        write_to_output_log "Settings file $settings_file not found, using default values."
        dpi=600
        set_margin=0.1
        retention_period=90
        direct_label_printer="" # Default empty if file not found
        test_mode="FALSE" # Default to FALSE if file not found
        write_to_output_log "Using default settings: DPI=$dpi, Set_Margin=$set_margin, Retention_Period=$retention_period, Direct_Label_Printer='$direct_label_printer', TestMode=$test_mode"
    fi

    # --- Determine if printing direct ---
    local print_direct="false"
    # Compare the original PRINTER environment variable (case-insensitive) to Direct_Label_Printer setting
    # Use lowercase conversion for case-insensitive comparison
    if [ -n "$original_printer" ] && [ -n "$direct_label_printer" ]; then
        if [[ "${original_printer,,}" == "${direct_label_printer,,}" ]]; then
            print_direct="true"
            write_to_output_log "Printer name ('$original_printer') matches Direct_Label_Printer ('$direct_label_printer'). Printing direct."
        else
             write_to_output_log "Printer name ('$original_printer') does not match Direct_Label_Printer ('$direct_label_printer'). Auto Cropping."
        fi
    else
        write_to_output_log "Direct_Label_Printer setting is not set. Auto Cropping."
    fi


    # --- Process PDF ---
    write_to_output_log "Processing PDF..."

    if [ "$print_direct" = "true" ]; then
        # If printing direct, just move the PDF to the output path
        write_to_output_log "Printing Direct: Moving $pdf_path to $output_path"
        mv "$pdf_path" "$output_path"
        # Check if the move was successful
        if [ $? -ne 0 ]; then
            write_to_output_log "Error: Failed to move PDF for direct printing."
            # Call cancel_cups_job before exiting on error
            cancel_cups_job "Failed to move PDF for direct printing"
            exit 1
        fi
        write_to_output_log "Direct printing move successful."
    else
        # If not printing direct, call the Auto Crop executable to process the PDF
        write_to_output_log "Calling Auto Crop for processing."
        # Call the Crop_PDF function
        Crop_PDF "$pdf_path" "$dpi" "$set_margin" "$output_path"
        # Check the exit status of the Crop_PDF function
        if [ $? -ne 0 ]; then
            write_to_output_log "Error during PDF Cropping."
            # Call cancel_cups_job before exiting on error
            cancel_cups_job "PDF cropping failed"
            exit 1 # Exit main with error status
        fi
        write_to_output_log "PDF cropped successfully."
    fi

    # --- Handle Output File (Copy, Delete Old, Print) ---
    # Consolidated check for the output PDF file existence
    if [ -f "$output_path" ]; then
        # Copy the output file to the /output folder
        write_to_output_log "Output PDF generated: $output_path"

        # Get the current date and time in the desired format for the filename
        timestamp=$(date +"%Y-%m-%d %H_%M_%S")

        # Define the new filename with the timestamp
        new_filename="$timestamp.pdf"
        local final_output_path="/output/$new_filename"

        # Write to the output log with the new filename
        write_to_output_log "Copying $output_path to $final_output_path"

        # Ensure the /output directory exists (optional, but good practice)
        if ! mkdir -p /output; then
            write_to_output_log "Error: Failed to create /output directory."
            # Continue, but log the error. No exit here as the main task might still succeed.
        fi

        # Copy the file with the new name
        if ! cp "$output_path" "$final_output_path"; then
            write_to_output_log "Error: Failed to copy output PDF to /output."
            # Continue, but log the error. No exit here as the main task might still succeed.
        fi
        write_to_output_log "Output PDF copied to /output."

        # Delete PDF files older than Retention_Period days in the /output folder
        write_to_output_log "Deleting PDF files older than $retention_period days in /output..."
        # Use the retention_period variable in the find command
        find /output -maxdepth 1 -type f -iregex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}_[0-9]{2}_[0_9]{2}\.pdf' -mtime +"$retention_period" -exec rm -f {} +
        # Check if the find/delete command had errors (though find's exit status can be tricky)
        if [ $? -ne 0 ]; then
             write_to_output_log "Warning: Errors encountered while deleting old files."
             # Continue, but log the warning
        fi
        write_to_output_log "Old files cleanup completed."


        # If not in TestMode, send the job to the real printer
        if [ "$test_mode" != "TRUE" ]; then
            write_to_output_log "Sending job to real Label Printer (Hidden_Label_Printer)."
            # Send the processed PDF to the hidden printer
            write_to_output_log "Sending job to physical printer."
            if ! lp -d Hidden_Label_Printer -o fit-to-page -o resolution=203dpi "$output_path"; then
                write_to_output_log "Error: lp command failed to send job to printer."
                # Continue, but log the error. The script will exit with success later if the output file exists.
            fi
        else
             write_to_output_log "TestMode is TRUE. Not sending job to physical printer."
        fi

        # Copy the process log to /output regardless of success/failure for review
        write_to_output_log "Copying process log to /output/"
        if [ -f "$job_dir/process_log.txt" ]; then # Check if log file exists before copying
            if ! cp "$job_dir/process_log.txt" /output/; then
                 write_to_output_log "Warning: Failed to copy process log to /output."
                 echo "Warning: Failed to copy process log to /output." >&2
                 # Continue, but log the warning
            fi
        else
            echo "JobCrop: Warning: Process log file not found at $job_dir/process_log.txt to copy." >&2
        fi

        # Exit successfully
        exit 0
    else
        # --- Error Handling if the output file does not exist ---
        write_to_output_log "Error processing labels: Output file not found."

        # Call cancel_cups_job before exiting on error
        cancel_cups_job "Output file not found after processing"

        # Copy the process log to /output even on failure for debugging
        write_to_output_log "Copying process log to /output/ on error."
        if [ -n "$job_dir" ] && [ -f "$job_dir/process_log.txt" ]; then # Check if log file exists before copying
            if ! cp "$job_dir/process_log.txt" /output/; then
                 write_to_output_log "Warning: Failed to copy process log to /output/ on error."
                 # Continue, but log the warning
            fi
        else
            echo "JobCrop: Warning: Process log file not found at $job_dir/process_log.txt to copy on error." >&2
        fi

        # Exit with error status
        exit 1
    fi
}

# Execute the main function
main
