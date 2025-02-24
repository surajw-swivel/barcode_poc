require_relative 'barcode_mask'
require_relative 'barcode_store'
require 'pdf-reader'
require 'tempfile'
require 'mini_magick'

class InvoiceProcessor
  MASK_PATTERN = {
    prefix: 1,      # * character
    ignore: 5,      # ##### (first 5 digits)
    crn: 12,        # RRRRRRRRRRRR (12 digits for CRN)
    ignore2: 8,     # ######## (8 digits to ignore)
    amount: 7       # $$$$$$$ (amount)
  }

  MASK = '*#####RRRRRRRRRRRR########$$$$$$$'

  def initialize(mask_pattern = MASK)
    @store = BarcodeStore.instance
  end

  def process_invoice(pdf_path)
    Rails.logger.info "Processing invoice from: #{pdf_path}"
    barcodes = scan_pdf_for_barcodes(pdf_path)
    
    Rails.logger.info "Found #{barcodes.length} barcodes: #{barcodes.inspect}"
    
    # Try each barcode until we find a match
    barcodes.each do |barcode|
      Rails.logger.info "Processing barcode: #{barcode}"
      
      data = parse_barcode(barcode)
      Rails.logger.info "Extracted data: #{data.inspect}"
      next unless data

      Rails.logger.info "Looking up CRN: #{data[:crn]}"
      provider_details = @store.find_by_crn(data[:crn])
      Rails.logger.info "Provider details lookup result: #{provider_details.inspect}"
      
      if provider_details
        Rails.logger.info "Found provider details: #{provider_details.inspect}"
        result = @store.add_to_history(barcode, true, provider_details)
        Rails.logger.info "Added to history: #{result.inspect}"
        
        return {
          success: true,
          crn: data[:crn],
          amount: data[:amount],
          provider_details: provider_details
        }
      else
        Rails.logger.info "No provider found for CRN: #{data[:crn]}"
        @store.add_to_history(barcode, false)
      end
    end

    # No valid barcode found
    if barcodes.any?
      Rails.logger.info "No valid barcode matched."
    else
      Rails.logger.info "No barcodes found in the PDF"
    end
    
    { success: false, error: "No valid barcode found" }
  end

  private

  def scan_pdf_for_barcodes(pdf_path)
    Rails.logger.info "Starting barcode scan for PDF: #{pdf_path}"
    Rails.logger.info "Running zbarimg command on PDF..."
    output = `zbarimg --quiet --raw #{pdf_path} 2>/dev/null`
    Rails.logger.info "zbarimg output: #{output}"
    
    # Split output into lines and remove empty lines
    barcodes = output.split("\n").reject(&:empty?)
    Rails.logger.info "Found #{barcodes.length} barcodes: #{barcodes.inspect}"
    barcodes
  end

  def parse_barcode(barcode)
    Rails.logger.info "\nRaw barcode: #{barcode}"
    return nil unless barcode.start_with?('*')

    # Remove the * prefix
    barcode = barcode[1..-1]
    Rails.logger.info "After prefix removal: #{barcode}"
    Rails.logger.info "Length: #{barcode.length}"
    
    # Calculate positions
    ignore_start = 0
    ignore_end = MASK_PATTERN[:ignore]
    crn_start = ignore_end
    crn_end = crn_start + MASK_PATTERN[:crn]
    ignore2_start = crn_end
    ignore2_end = ignore2_start + MASK_PATTERN[:ignore2]
    amount_start = ignore2_end
    
    Rails.logger.info "Positions:"
    Rails.logger.info "Ignore: #{ignore_start}...#{ignore_end}"
    Rails.logger.info "CRN: #{crn_start}...#{crn_end}"
    Rails.logger.info "Ignore2: #{ignore2_start}...#{ignore2_end}"
    Rails.logger.info "Amount: #{amount_start}..-1"
    
    # Extract parts according to mask pattern
    parts = {
      ignore1: barcode[0...MASK_PATTERN[:ignore]],
      crn: barcode[MASK_PATTERN[:ignore], MASK_PATTERN[:crn]],
      ignore2: barcode[MASK_PATTERN[:ignore] + MASK_PATTERN[:crn], MASK_PATTERN[:ignore2]],
      amount: barcode[-MASK_PATTERN[:amount]..-1]
    }

    Rails.logger.info "\nExtracted parts:"
    Rails.logger.info "Ignore1 (#{parts[:ignore1].length} chars): #{parts[:ignore1]}"
    Rails.logger.info "CRN (#{parts[:crn].length} chars): #{parts[:crn]}"
    Rails.logger.info "Ignore2 (#{parts[:ignore2].length} chars): #{parts[:ignore2]}"
    Rails.logger.info "Amount (#{parts[:amount].length} chars): #{parts[:amount]}"

    # Validate parts
    if parts[:crn].nil? || parts[:amount].nil? || 
       parts[:crn].length != MASK_PATTERN[:crn] || 
       parts[:amount].length != MASK_PATTERN[:amount]
      Rails.logger.info "Invalid parts lengths"
      return nil
    end

    # Convert amount to decimal (last two digits are cents)
    amount = parts[:amount].to_i / 100.0
    Rails.logger.info "\nParsed amount: $#{sprintf('%.2f', amount)} from #{parts[:amount]}"
    
    {
      crn: parts[:crn],
      amount: amount,
      raw_barcode: barcode
    }
  end

end
