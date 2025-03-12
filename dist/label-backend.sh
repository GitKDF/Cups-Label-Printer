#!/bin/bash

job_dir=""

# Function to write to the output log
write_to_output_log() {
    local message=$1
    if [ -f "$job_dir/process_log.txt" ]; then
        echo "JobCrop: $message" >> "$job_dir/process_log.txt"
    fi
    echo $message >&2
}

process_ps() {
    local ps_bytes="$1"
    local pdf_path="$job_dir/label_input.pdf"

    # Convert PostScript to PDF using pstopdf
    export DEVICE_URI="file:///dev/null"
    export PRINTER="Label_Printer"
    export PPD="/etc/cups/ppd/dummy.ppd"

    write_to_output_log "Converting PostScript to PDF: $pdf_path"
    echo "$ps_bytes" | /usr/lib/cups/filter/pstopdffx 1 1 1 1 > "$pdf_path"

    # Check if settings.txt exists
    if [ -f /etc/cups/process_labels/settings.txt ]; then
        # Get values from settings.txt
        write_to_output_log "Getting values from settings.txt"
        local dpi=$(grep dpi /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')
        local error_margin_percent=$(grep error_margin_percent /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')
        local set_margin=$(grep set_margin /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')
        local ant_threshold=$(grep ant_threshold /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')
    else
        # Use default values if settings.txt doesn't exist
        write_to_output_log "settings.txt doesn't exist, using default values."
        local dpi=600
        local error_margin_percent=20
        local set_margin=0.1
        local ant_threshold=0.2
    fi

    # Process PDF
    write_to_output_log "Calling process_labels.elf \"$pdf_path\" \"$dpi\" \"$error_margin_percent\" \"$set_margin\" \"$output_path\" \"$ant_threshold\""
    /etc/cups/process_labels/process_labels.elf "$pdf_path" "$dpi" "$error_margin_percent" "$set_margin" "$output_path" "$ant_threshold"
}

main() {
    # Delete old JobX folders
    find /tmp -maxdepth 1 -type d -name 'Job[0-9]*' -mtime +1 -exec rm -rf {} +

    # Create a new JobX folder
    for i in {1..1000}; do
        if [ ! -d "/tmp/Job$i" ]; then
            job_dir="/tmp/Job$i"
            mkdir "$job_dir"
            break
        fi
    done

    output_path="$job_dir/label_print_job.pdf"

    # Create a new output log
    touch "$job_dir/process_log.txt"
    
    # Read input data from stdin
    local input_data
    input_data=$(cat)

    # Save input_data to job_dir/input_postscript.ps
    echo "$input_data" > "$job_dir/input_postscript.ps"
    
    # Process the PostScript
    write_to_output_log "Processing input postscript."
    process_ps "$input_data"

    # Check for TestMode in settings.txt
    test_mode=$(grep TestMode /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')
    
    # Check if TestMode is set to TRUE
    if [ -f "$output_path" ]; then
        # Copy the output file to the /output folder
        
        # Get the current date and time in the desired format
        timestamp=$(date +"%Y-%m-%d %H_%M_%S")
        
        # Define the new filename with the timestamp
        new_filename="$timestamp.pdf"
        
        # Write to the output log with the new filename
        write_to_output_log "Copying $output_path to /output/$new_filename"
        
        # Copy the file with the new name
        cp "$output_path" "/output/$new_filename"

        # Delete PDF files older than 90 days in the /output folder
        find /output -maxdepth 1 -type f -iregex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}_[0-9]{2}_[0-9]{2}\.pdf' -mtime +90 -exec rm -f {} +

        if [ "$test_mode" != "TRUE" ]; then
            # Send Job to real Label Printer
            lp -d Hidden_Label_Printer -o fit-to-page -o resolution=203dpi "$job_dir/label_print_job.pdf"
        fi
    fi

    if [ $? -eq 0 ] && [ -f "$output_path" ]; then
        if [ "$test_mode" = "TRUE" ]; then
            write_to_output_log "Processed job sent to /output/"
        else
            write_to_output_log "Processed job sent to Physical Label Printer"
        fi
        cp "$job_dir/process_log.txt" /output/
        exit 0
    else
        write_to_output_log "Error processing labels"
        
        # Get the Job ID from Env Variable
        local job_id
        job_id=$(echo $CUPS_JOBID)
        if [ -n "$job_id" ]; then
            # Cancel the job
            cancel "$job_id"
            write_to_output_log "Cancelled job $job_id"
        fi

        cp "$job_dir/process_log.txt" /output/

        echo -e "\a\a\a"
        
        exit 1
    fi
}

main
