#!/bin/bash

output_path="/tmp/label_print_job.pdf"

# Function to create or clear the output log
create_output_log() {
    if [ ! -d "/output" ]; then
        mkdir -p /output
    fi

    if [ -f "/output/process_log.txt" ]; then
        > /output/process_log.txt
    else
        touch /output/process_log.txt
    fi
}

# Function to write to the output log
write_to_output_log() {
    local message=$1
    if [ -f "/output/process_log.txt" ]; then
        echo "$message" >> /output/process_log.txt
    fi
    echo $message >&2
}

process_ps() {
    local ps_bytes="$1"
    local pdf_path="/tmp/label_input.pdf"

    # Convert PostScript to PDF using pstopdf
    export DEVICE_URI="file:///dev/null"
    export PRINTER="Label_Printer"
    export PPD="/etc/cups/ppd/dummy.ppd"

    write_to_output_log "JobCrop: Converting PostScript to PDF: $pdf_path"
    echo "$ps_bytes" | /usr/lib/cups/filter/pstopdffx 1 1 1 1 > "$pdf_path"

    # Check if settings.txt exists
    if [ -f /etc/cups/process_labels/settings.txt ]; then
        # Get values from settings.txt
        write_to_output_log "JobCrop: Getting values from settings.txt"
        local dpi=$(grep dpi /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')
        local error_margin_percent=$(grep error_margin_percent /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')
        local set_margin=$(grep set_margin /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')
        local ant_threshold=$(grep ant_threshold /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')
    else
        # Use default values if settings.txt doesn't exist
        write_to_output_log "JobCrop: settings.txt doesn't exist, using defualt values."
        local dpi=600
        local error_margin_percent=20
        local set_margin=0.1
        local ant_threshold=0.2
    fi

    # Process PDF
    write_to_output_log "JobCrop: Calling process_labels.elf \"$pdf_path\" \"$dpi\" \"$error_margin_percent\" \"$set_margin\" \"$output_path\" \"$ant_threshold\""
    /etc/cups/process_labels/process_labels.elf "$pdf_path" "$dpi" "$error_margin_percent" "$set_margin" "$output_path" "$ant_threshold"
}

main() {
    # Read input data from stdin
    local input_data
    input_data=$(cat)

    # Check for TestMode in settings.txt
    test_mode=$(grep TestMode /etc/cups/process_labels/settings.txt | awk -F '=' '{print $2}')

    if [ "$test_mode" = "TRUE" ]; then
        create_output_log
    fi
    
    # Process the PostScript
    write_to_output_log "JobCrop: Processing input file $input_data"
    process_ps "$input_data"

    # Check if TestMode is set to TRUE
    if [ "$test_mode" = "TRUE" ]; then
        # Copy the output file to the /output folder
        write_to_output_log "JobCrop: Copying $output_path to /output/"
        cp "$output_path" /output/
    else
        # Send Job to real Label Printer
        lp -d Hidden_Label_Printer -o fit-to-page -o resolution=203dpi /tmp/label_print_job.pdf
    fi

    if [ $? -eq 0 ]; then
        if [ "${TestMode:-}" = "TRUE" ]; then
            write_to_output_log "JobCrop: Processed job sent to /output/"
        else
            write_to_output_log "JobCrop: Processed job sent to Physical Label Printer"
        fi
        exit 0
    else
        write_to_output_log "JobCrop: Error processing PostScript"
        
        # Get the Job ID from Env Variable
        local job_id
        job_id=$(echo $CUPS_JOBID)
        if [ -n "$job_id" ]; then
            # Cancel the job
            cancel "$job_id"
            write_to_output_log "Cancelled job $job_id"
        fi

        exit 1
    fi
}

main
