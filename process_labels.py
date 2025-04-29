import fitz  # PyMuPDF
import cv2
import numpy as np
import os
import argparse
import sys

log_path = "./process_log.txt"

# Function to log errors
def log_message(message):
    if os.path.exists(log_path):
        with open(log_path, 'a') as log_file:
            log_file.write("JobCrop: ProcPDF: " + message + "\n")
            log_file.flush()

# Custom error handler for the argument parser
class CustomArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        log_message(f"Argument error: {message}")
        super().error(message)

def crop_whitespace(image):
    log_message("Starting to remove whitespace.")
    _, thresh = cv2.threshold(image, 240, 255, cv2.THRESH_BINARY)
    thresh_inv = cv2.bitwise_not(thresh)
    non_zero_points = cv2.findNonZero(thresh_inv)
    if non_zero_points is not None and len(non_zero_points) > 0:
        x, y, w, h = cv2.boundingRect(non_zero_points)
        cropped_image = image[y:y+h, x:x+w]
        cropped_rect = (x, y, w, h)
        log_message(f"Whitespace removed. Bounding box: ({x}, {y}, {w}, {h})")
        return cropped_image, cropped_rect
    else:
        height, width = image.shape[:2]
        log_message("No non-zero points found after thresholding.")
        return image, (0, 0, width, height)

def process_rect(rect, doc, page_num, output_doc, dpi, set_margin, x_offset, y_offset):
    try:
        margin = set_margin * 72  # Convert margin from inches to points
        x, y, w, h = rect

        # Convert rect values from pixels to points
        x = (x * 72 / dpi) + x_offset
        y = (y * 72 / dpi) + y_offset
        w = w * 72 / dpi
        h = h * 72 / dpi

        if w > h:
            new_page = output_doc.new_page(width=6 * 72, height=4 * 72)
            adjusted_rect = fitz.Rect(margin, margin, 6 * 72 - margin, 4 * 72 - margin)
            new_page.show_pdf_page(adjusted_rect, doc, page_num, clip=fitz.Rect(x, y, x + w, y + h))
            new_page.set_rotation(90)
        else:
            new_page = output_doc.new_page(width=4 * 72, height=6 * 72)
            adjusted_rect = fitz.Rect(margin, margin, 4 * 72 - margin, 6 * 72 - margin)
            new_page.show_pdf_page(adjusted_rect, doc, page_num, clip=fitz.Rect(x, y, x + w, y + h))
        log_message(f"Processed rectangle: {rect}")
    except Exception as e:
        log_message(f"Error processing rectangle: {str(e)}")
        raise

def process_page(doc, page_num, clip_rect, dpi, set_margin, output_doc):
    try:
        page = doc.load_page(page_num)
        pix = page.get_pixmap(dpi=dpi, clip=clip_rect)
        img_np = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)

        # Convert the image to grayscale
        gray_img = cv2.cvtColor(img_np, cv2.COLOR_RGB2GRAY)

        # Apply the threshold
        threshold = 20
        _, thresholded_img = cv2.threshold(gray_img, threshold, 255, cv2.THRESH_BINARY)

        # Crop Image of whitespace
        cropped_image, cropped_rect = crop_whitespace(thresholded_img)

        process_rect(cropped_rect, doc, page_num, output_doc, dpi, set_margin, clip_rect.x0, clip_rect.y0)
        log_message(f"Processed page {page_num + 1} with clip_rect {clip_rect}")
        return True
    except Exception as e:
        log_message(f"Error processing page {page_num + 1}: {str(e)}")
        raise

def process_document_page(doc, page_num, dpi, set_margin, output_doc):
    try:
        log_message(f"Starting to process document page {page_num + 1}.")
        # Initial call with the whole page boundary
        page = doc.load_page(page_num)
        page.set_rotation(0)
        rect = fitz.Rect(0, 0, page.rect.width, page.rect.height)

        return process_page(doc, page_num, rect, dpi, set_margin, output_doc)

        log_message(f"Finished processing document page {page_num + 1}.")
    except Exception as e:
        log_message(f"Error processing document page {page_num + 1}: {str(e)}")
        raise

def process_pdf(pdf_path, dpi, set_margin, output_path):
    try:
        log_message(f"Starting to process PDF: {pdf_path}")
        doc = fitz.open(pdf_path)
        output_doc = fitz.open()

        success = False
        for page_num in range(len(doc)):
            pagesuccess = process_document_page(doc, page_num, dpi, set_margin, output_doc)
            success = success or pagesuccess
            if not pagesuccess:
                log_message(f"No Label Detected on Page {page_num + 1}")

        if not success:
            return False

        output_doc.save(output_path)
        log_message(f"Finished processing PDF. Output saved to: {output_path}")
        return True
    except Exception as e:
        log_message(f"Error processing PDF: {str(e)}")
        raise

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Process a PDF document.")
    parser.add_argument("pdf_path", type=str, help="Path to the input PDF file.")
    parser.add_argument("dpi", type=int, help="DPI for processing the PDF.")
    parser.add_argument("set_margin", type=float, help="Margin to set in inches.")
    parser.add_argument("output_path", type=str, help="Path to save the output PDF file.")

    try:
        args = parser.parse_args()

        # Extract the directory path from output_path and set log_path
        log_path = os.path.join(os.path.dirname(args.output_path), "process_log.txt")

        success = process_pdf(args.pdf_path, args.dpi, args.set_margin, args.output_path)
        if not success:
            log_message("No Labels Detected.")
            sys.exit(1)  # Exit with non-zero code if no labels were detected
    except Exception as e:
        log_message(f"An error occurred: {str(e)}")
        raise
