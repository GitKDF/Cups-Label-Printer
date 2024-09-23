import fitz  # PyMuPDF
from PIL import Image, ImageOps
import cv2
import numpy as np
import os
import argparse
import sys

log_path = "/tmp/process_log.txt"

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

# Initialize the log file at the start of the script
initialize_log()

def isPage4by6(rect):
    # Define the dimensions in points (1 inch = 72 points)
    width_4_inch = 4 * 72
    height_6_inch = 6 * 72

    # Check if the rect matches 4"x6" or 6"x4"
    if (rect.width == width_4_inch and rect.height == height_6_inch) or \
       (rect.width == height_6_inch and rect.height == width_4_inch):
        return True
    return False

def marginNeeded(doc, page_num, set_margin):
    # Convert set_margin from inches to points (1 inch = 72 points)
    margin_points = set_margin * 72
    
    # Convert the page to an image at 72 dpi
    page = doc.load_page(page_num)
    pix = page.get_pixmap(dpi=72)
    img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
    
    # Convert the image to grayscale
    img = img.convert("L")
    
    # Apply thresholding
    threshold = 127
    img = img.point(lambda p: p > threshold and 255)
    
    # Convert image to numpy array for pixel manipulation
    img_array = np.array(img)
    
    # Function to check if the border pixels are all white
    def is_border_white(image):
        return (image[0, :] == 255).all() and (image[-1, :] == 255).all() and \
               (image[:, 0] == 255).all() and (image[:, -1] == 255).all()
    
    cropped_pixels = 0
    
    # Loop to crop the image
    while cropped_pixels < margin_points:
        if is_border_white(img_array):
            img_array = img_array[1:-1, 1:-1]
            cropped_pixels += 1
        else:
            break
    
    # Return the converted value of set_margin minus the number of pixels cropped
    return margin_points - cropped_pixels

def crop_whitespace(image, dpi, ant_threshold):
    def remove_whitespace(image):
        log_message("Starting to remove whitespace.")
        open_cv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
        gray = cv2.cvtColor(open_cv_image, cv2.COLOR_BGR2GRAY)
        _, thresh = cv2.threshold(gray, 240, 255, cv2.THRESH_BINARY)
        thresh_inv = cv2.bitwise_not(thresh)
        non_zero_points = cv2.findNonZero(thresh_inv)
        x, y, w, h = cv2.boundingRect(non_zero_points)
        cropped_image = open_cv_image[y:y+h, x:x+w]
        log_message(f"Whitespace removed. Bounding box: ({x}, {y}, {w}, {h})")
        return cropped_image, (x, y, w, h)

    def remove_ants(cropped_image, cropped_rect, dpi, ant_threshold):
        log_message("Starting to remove ants.")
        cropped_image = Image.fromarray(cv2.cvtColor(cropped_image, cv2.COLOR_BGR2RGB))
        width, height = cropped_image.size
        cropped_pixels = 0

        ant_threshold_pixels = ant_threshold * dpi

        while True:
            log_message(f"Checking border pixels. Cropped pixels: {cropped_pixels}")
            border_white = all(cropped_image.getpixel((x, 0)) == (255, 255, 255) for x in range(width)) and \
                           all(cropped_image.getpixel((x, height-1)) == (255, 255, 255) for x in range(width)) and \
                           all(cropped_image.getpixel((0, y)) == (255, 255, 255) for y in range(height)) and \
                           all(cropped_image.getpixel((width-1, y)) == (255, 255, 255) for y in range(height))

            if border_white:
                log_message("Border pixels are all white.")
                cropped_image_np = np.array(cropped_image)
                cropped_image_np = cv2.cvtColor(cropped_image_np, cv2.COLOR_RGB2BGR)
                cropped_image, (x, y, w, h) = remove_whitespace(cropped_image_np)
                log_message(f"Ants removed. New bounding box: ({x}, {y}, {w}, {h})")
                return cropped_image, (cropped_rect[0] + x + cropped_pixels, cropped_rect[1] + y + cropped_pixels, w, h)

            cropped_image = cropped_image.crop((1, 1, width - 1, height - 1))
            width, height = cropped_image.size
            cropped_pixels += 1

            if cropped_pixels > ant_threshold_pixels:
                log_message("Ant threshold exceeded.")
                return cropped_image, cropped_rect

    log_message("Starting initial crop to remove whitespace.")
    cropped_image, cropped_rect = remove_whitespace(image)

    log_message("Starting further crop to remove ants.")
    cropped_image, cropped_rect = remove_ants(cropped_image, cropped_rect, dpi, ant_threshold)

    log_message("Cropping complete.")
    return cropped_image, cropped_rect

def check_dimensions(image, target_width, target_height, dpi, error_margin_percent):
    log_message("Checking dimensions.")
    image = np.array(image)
    
    height, width = image.shape[:2]
    error_margin = error_margin_percent / 100.0
    
    target_width_px = target_width * dpi
    target_height_px = target_height * dpi
    
    width_within_margin = abs(width - target_width_px) <= target_width_px * error_margin
    height_within_margin = abs(height - target_height_px) <= target_height_px * error_margin
    
    log_message(f"Dimensions check: width_within_margin={width_within_margin}, height_within_margin={height_within_margin}")
    return width_within_margin and height_within_margin

def check_ratio(image, target_width, target_height, dpi, error_margin_percent):
    log_message("Checking ratio.")
    image = np.array(image)
    
    height, width = image.shape[:2]
    error_margin = error_margin_percent / 100.0
    
    target_ratio = min(target_width, target_height) / max(target_width, target_height)
    image_ratio = min(height, width) / max(height, width)
    
    ratio_within_margin = abs(image_ratio - target_ratio) <= target_ratio * error_margin
    
    log_message(f"Ratio check: ratio_within_margin={ratio_within_margin}")
    return ratio_within_margin

def validate_barcode_and_separator(image, dpi):
    log_message("Validating barcode and separator.")
    image = np.array(image)
    
    height, width = image.shape[:2]
    
    if width > height:
        log_message("Rotating image.")
        image = cv2.rotate(image, cv2.ROTATE_90_CLOCKWISE)
        height, width = image.shape[:2]
    
    crop_margin = int(0.1 * dpi)
    image = image[crop_margin:height-crop_margin, crop_margin:width-crop_margin]
    height, width = image.shape[:2]
    
    barcode_found = False
    black_line_found = False
    counter = 0
    
    for i in range(1, height):
        row = image[i]
        prev_row = image[i-1]
        
        if np.all(row == 0):
            black_line_found = True
            log_message("Black line found.")
        
        if not np.all(row == 255) and not np.all(row == 0) and np.array_equal(row, prev_row):
            counter += 1
        else:
            counter = 0
        
        if counter >= 0.5 * dpi:
            non_white_indices = np.where(row != 255)[0]
            if len(non_white_indices) > 0:
                left = non_white_indices[0]
                right = non_white_indices[-1]
                cropped_row = row[left:right+1]
                
                if len(cropped_row) >= 0.65 * width:
                    barcode_found = True
                    log_message("Barcode found.")
        
        if barcode_found and black_line_found:
            log_message("Barcode and black line found.")
            return True
    
    log_message("Barcode and black line not found.")
    return False

def process_document_page(doc, page_num, dpi, error_margin_percent, set_margin, output_doc, ant_threshold):
    def process_rect(rect, doc, page_num, output_doc, dpi, set_margin, x_offset, y_offset):
        try:
            margin = set_margin * 72  # Convert margin from inches to points
            
            # Convert rect values from pixels to points
            x, y, w, h = rect
            x = ( x * 72 / dpi ) + x_offset
            y = ( y * 72 / dpi ) + y_offset
            w = w * 72 / dpi
            h = h * 72 / dpi

            # if page is 4*6 and rect is the full page rect, set margin needed to get full margin width in white.
            if (doc[page_num].rect == rect) and isPage4by6(rect):
                margin = marginNeeded(doc, page_num, set_margin)

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

    def process_page(doc, page_num, clip_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold):
        try:
            if isPage4by6(clip_rect):
                process_rect(clip_rect, doc, page_num, output_doc, dpi, set_margin, clip_rect.x0, clip_rect.y0)
                log_message(f"Processed page {page_num} with clip_rect {clip_rect}")
                return True
                
            page = doc.load_page(page_num)
            pix = page.get_pixmap(dpi=dpi, clip=clip_rect)
            img = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
        
            # Convert the PIL image to a NumPy array
            img_np = np.array(img)
            
            # Convert the image to grayscale
            gray_img = cv2.cvtColor(img_np, cv2.COLOR_RGB2GRAY)
            
            # Apply the threshold
            threshold = 20
            _, thresholded_img = cv2.threshold(gray_img, threshold, 255, cv2.THRESH_BINARY)
            
            # Convert the modified image back to a PIL image
            img = Image.fromarray(thresholded_img)

            # Crop Image of whitespace and ants
            cropped_image, cropped_rect = crop_whitespace(img, dpi, ant_threshold)
            
            # Initialize valid_dimensions to False
            valid_dimensions = False
            
            # Check if clip_rect is equal to page.rect
            if clip_rect == page.rect:
                # Check for valid dimensions or valid ratio
                valid_dimensions = (
                    check_dimensions(cropped_image, 4, 6, dpi, error_margin_percent) or 
                    check_dimensions(cropped_image, 6, 4, dpi, error_margin_percent) or
                    check_ratio(cropped_image, 4, 6, dpi, error_margin_percent)
                )
            else:
                # Check if page.rect.width is greater than page.rect.height and check for corresponding valid dimensions
                if page.rect.width > page.rect.height:
                    valid_dimensions = check_dimensions(cropped_image, 4, 6, dpi, error_margin_percent)
                else:
                    valid_dimensions = check_dimensions(cropped_image, 6, 4, dpi, error_margin_percent)
            
            if valid_dimensions:
                if validate_barcode_and_separator(cropped_image, dpi):
                    process_rect(cropped_rect, doc, page_num, output_doc, dpi, set_margin, clip_rect.x0, clip_rect.y0)
                    log_message(f"Processed page {page_num} with clip_rect {clip_rect}")
                    return True
            log_message(f"Page {page_num} did not meet validation criteria.")
            return False
        except Exception as e:
            log_message(f"Error processing page {page_num}: {str(e)}")
            raise

    try:
        log_message(f"Starting to process document page {page_num}.")
        # Initial call with the whole page boundary
        page = doc.load_page(page_num)
        page.set_rotation(0)
        rect = fitz.Rect(0, 0, page.rect.width, page.rect.height)
        
        if process_page(doc, page_num, rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold):
            return True
        else:
            if rect.width > rect.height:
                # Split the page into left and right halves
                left_rect = fitz.Rect(0, 0, 5.25 * 72, rect.height)            # left 5.25" time 72 points per inch
                right_rect = fitz.Rect(5.75 * 72, 0, rect.width, rect.height)  # right 5.25" time 72 points per inch
                
                # Process the left and right halves
                result = process_page(doc, page_num, left_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)
                result = result or process_page(doc, page_num, right_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)
                return result
            else:
                # Split the page into top and bottom halves
                top_rect = fitz.Rect(0, 0, rect.width, 5.25 * 72)               # top 5.25" time 72 points per inch
                bottom_rect = fitz.Rect(0, 5.75 * 72, rect.width, rect.height)  # bottom 5.25" time 72 points per inch
                
                # Process the top and bottom halves
                result = process_page(doc, page_num, top_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)
                result = result or process_page(doc, page_num, bottom_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)
                return result
        log_message(f"Finished processing document page {page_num}.")
    except Exception as e:
        log_message(f"Error processing document page {page_num}: {str(e)}")
        raise

def process_pdf(pdf_path, dpi, error_margin_percent, set_margin, output_path, ant_threshold):
    try:
        log_message(f"Starting to process PDF: {pdf_path}")
        doc = fitz.open(pdf_path)
        output_doc = fitz.open()
        
        success = False
        for page_num in range(len(doc)):
            success = success or process_document_page(doc, page_num, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)

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
    parser.add_argument("error_margin_percent", type=float, help="Error margin percentage for dimension checks.")
    parser.add_argument("set_margin", type=float, help="Margin to set in inches.")
    parser.add_argument("output_path", type=str, help="Path to save the output PDF file.")
    parser.add_argument("ant_threshold", type=float, help="Ant threshold in inches.")
    
    try:
        args = parser.parse_args()
        success = process_pdf(args.pdf_path, args.dpi, args.error_margin_percent, args.set_margin, args.output_path, args.ant_threshold)
        if not success:
            log_message("No Labels Detected.")
            sys.exit(1)  # Exit with non-zero code if no labels were detected
    except Exception as e:
        log_message(f"An error occurred: {str(e)}")
        raise
