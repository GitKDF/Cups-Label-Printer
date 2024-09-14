import fitz  # PyMuPDF
from PIL import Image
import cv2
import numpy as np
import argparse

def crop_whitespace(image, dpi, ant_threshold):
    def remove_whitespace(image):
        open_cv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
        gray = cv2.cvtColor(open_cv_image, cv2.COLOR_BGR2GRAY)
        _, thresh = cv2.threshold(gray, 240, 255, cv2.THRESH_BINARY)
        thresh_inv = cv2.bitwise_not(thresh)
        non_zero_points = cv2.findNonZero(thresh_inv)
        x, y, w, h = cv2.boundingRect(non_zero_points)
        cropped_image = open_cv_image[y:y+h, x:x+w]
        return cropped_image, (x, y, w, h)

    def remove_ants(cropped_image, cropped_rect, dpi, ant_threshold):
        cropped_image = Image.fromarray(cv2.cvtColor(cropped_image, cv2.COLOR_BGR2RGB))
        width, height = cropped_image.size
        cropped_pixels = 0

        ant_threshold_pixels = ant_threshold * dpi

        while True:
            # Check if the border pixels are all white
            border_white = all(cropped_image.getpixel((x, 0)) == (255, 255, 255) for x in range(width)) and \
                           all(cropped_image.getpixel((x, height-1)) == (255, 255, 255) for x in range(width)) and \
                           all(cropped_image.getpixel((0, y)) == (255, 255, 255) for y in range(height)) and \
                           all(cropped_image.getpixel((width-1, y)) == (255, 255, 255) for y in range(height))

            if border_white:
                # Find the bounding box of non-white pixels
                cropped_image_np = np.array(cropped_image)
                cropped_image_np = cv2.cvtColor(cropped_image_np, cv2.COLOR_RGB2BGR)
                cropped_image, (x, y, w, h) = remove_whitespace(cropped_image_np)
                return cropped_image, (cropped_rect[0] + x + cropped_pixels, cropped_rect[1] + y + cropped_pixels, w, h)

            cropped_image = cropped_image.crop((1, 1, width - 1, height - 1))
            width, height = cropped_image.size
            cropped_pixels += 1

            if cropped_pixels > ant_threshold_pixels:
                return cropped_image, cropped_rect

    # Initial crop to remove whitespace
    cropped_image, cropped_rect = remove_whitespace(image)

    # Further crop to remove ants
    cropped_image, cropped_rect = remove_ants(cropped_image, cropped_rect, dpi, ant_threshold)

    return cropped_image, cropped_rect

def check_dimensions(image, target_width, target_height, dpi, error_margin_percent):
    height, width = image.shape[:2]
    error_margin = error_margin_percent / 100.0
    
    # Calculate the target dimensions in pixels
    target_width_px = target_width * dpi
    target_height_px = target_height * dpi
    
    # Check if the actual dimensions are within the error margin
    width_within_margin = abs(width - target_width_px) <= target_width_px * error_margin
    height_within_margin = abs(height - target_height_px) <= target_height_px * error_margin
    
    return width_within_margin and height_within_margin

def process_document_page(doc, page_num, dpi, error_margin_percent, set_margin, output_doc, ant_threshold):
    def process_rect(rect, doc, page_num, output_doc, dpi, set_margin, x_offset, y_offset):
        margin = set_margin * 72  # Convert margin from inches to points
        
        # Convert rect values from pixels to points
        x, y, w, h = rect
        x = ( x * 72 / dpi ) + x_offset
        y = ( y * 72 / dpi ) + y_offset
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

    def process_page(doc, page_num, clip_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold):
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
            valid_dimensions = (
                check_dimensions(cropped_image, 4, 6, dpi, error_margin_percent) or 
                check_dimensions(cropped_image, 6, 4, dpi, error_margin_percent)
            )
        else:
            # Check if page.rect.width is greater than page.rect.height
            if page.rect.width > page.rect.height:
                valid_dimensions = check_dimensions(cropped_image, 4, 6, dpi, error_margin_percent)
            else:
                valid_dimensions = check_dimensions(cropped_image, 6, 4, dpi, error_margin_percent)
        
        # Use valid_dimensions in your original line
        if valid_dimensions:
            process_rect(cropped_rect, doc, page_num, output_doc, dpi, set_margin, clip_rect.x0, clip_rect.y0)
            return True
        return False

    # Initial call with the whole page boundary
    page = doc.load_page(page_num)
    page.set_rotation(0)
    rect = fitz.Rect(0, 0, page.rect.width, page.rect.height)
    
    if not process_page(doc, page_num, rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold):
        # Create a temporary document to handle splitting
        temp_doc = fitz.open()
        if rect.width > rect.height:
            # Split the page into left and right halves
            left_rect = fitz.Rect(0, 0, rect.width / 2, rect.height)
            right_rect = fitz.Rect(rect.width / 2, 0, rect.width, rect.height)
            
            # Process the left and right halves
            process_page(doc, page_num, left_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)
            process_page(doc, page_num, right_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)
        else:
            # Split the page into top and bottom halves
            top_rect = fitz.Rect(0, 0, rect.width, rect.height / 2)
            bottom_rect = fitz.Rect(0, rect.height / 2, rect.width, rect.height)
            
            # Process the left and right halves
            process_page(doc, page_num, top_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)
            process_page(doc, page_num, bottom_rect, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)

def process_pdf(pdf_path, dpi, error_margin_percent, set_margin, output_path, ant_threshold):
    doc = fitz.open(pdf_path)
    output_doc = fitz.open()
    
    for page_num in range(len(doc)):
        process_document_page(doc, page_num, dpi, error_margin_percent, set_margin, output_doc, ant_threshold)
    
    output_doc.save(output_path)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Process a PDF document.")
    parser.add_argument("pdf_path", type=str, help="Path to the input PDF file.")
    parser.add_argument("dpi", type=int, help="DPI for processing the PDF.")
    parser.add_argument("error_margin_percent", type=float, help="Error margin percentage for dimension checks.")
    parser.add_argument("set_margin", type=float, help="Margin to set in inches.")
    parser.add_argument("output_path", type=str, help="Path to save the output PDF file.")
    parser.add_argument("ant_threshold",
