#!/bin/bash

process_ps() {
    local ps_bytes="$1"
    local pdf_path="/tmp/label_input.pdf"

    # Convert PostScript to PDF using pstopdf
    export DEVICE_URI="file:///dev/null"
    export PRINTER="Label_Printer"
    export PPD="/etc/cups/ppd/dummy.ppd"

    echo "$ps_bytes" | /usr/lib/cups/filter/pstopdffx 1 1 1 1 > "$pdf_path"

    # Process PDF
    /usr/lib/cups/process_labels.py "$pdf_path" "$dpi" "$error_margin_percent" "$set_margin" "$output_path" "$ant_threshold"
    
    # Check if process_labels.py exited successfully
    if [ $? -ne 0 ]; then
        echo "Error processing labels" >&2
        exit 1
    fi

    # Copy the output file to the /output folder
    cp "$output_path" /output/
}

main() {
    # Read input data from stdin
    local input_data
    input_data=$(cat)

    # Process the PostScript
    process_ps "$input_data"

    lp -d Zebra_Label_Printer -o fit-to-page -o resolution=203dpi /tmp/label_print_job.pdf

    if [ $? -eq 0 ]; then
        echo "JobCrop: Processed job sent to Zebra Printer" >&2
        exit 0
    else
        echo "Error processing PostScript" >&2
        
        # Get the Job ID from Env Variable
        local job_id
        job_id=$(echo $CUPS_JOBID)
        if [ -n "$job_id" ]; then
            # Cancel the job
            cancel "$job_id"
            echo "Cancelled job $job_id" >&2
        fi

        exit 1
    fi
}

main
