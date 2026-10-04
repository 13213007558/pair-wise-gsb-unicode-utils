# -*- encoding: utf-8 -*-

module UnicodeUtils

  # Standard Compression Scheme for Unicode (SCSU), UTS #22.
  module SCSU

    class InvalidEncoding < StandardError; end

    INITIAL_DYNAMIC_OFFSETS = [
      0x0000, 0x0080, 0x0100, 0x0300, 0x2000, 0x2080,
      0x2100, 0x3000
    ].freeze

    STATIC_OFFSETS = [
      0x0080, 0x00C0, 0x0400, 0x0600, 0x0900, 0x3040,
      0x30A0, 0xFF00
    ].freeze

    SPECIAL_DYNAMIC_OFFSETS = {
      0xF9 => 0x00000,
      0xFA => 0x00210,
      0xFB => 0x02F0,
      0xFC => 0x0530,
      0xFD => 0x3000,
      0xFE => 0x3080,
      0xFF => 0xFF00
    }.freeze

    def self.dynamic_offset(selector)
      if selector.between?(0x01, 0x67)
        (selector - 1) * 0x80
      elsif selector.between?(0x68, 0xA6)
        0xDF80 + (selector - 0x68) * 0x80
      elsif SPECIAL_DYNAMIC_OFFSETS.include?(selector)
        SPECIAL_DYNAMIC_OFFSETS[selector]
      end
    end

    def self.dynamic_position(code_point)
      if code_point < 0x3400
        aligned_low = code_point % 0x80
        if aligned_low.between?(0x20, 0x7F)
          selector = code_point / 0x80 + 1
          SPECIAL_DYNAMIC_OFFSETS.each do |special_selector, special_offset|
            special_low = code_point - special_offset
            if special_low == aligned_low
              return [special_selector, aligned_low]
            elsif special_low.between?(0xA0, 0xFF)
              return [special_selector, special_low]
            end
          end
          return [selector, aligned_low]
        end
      elsif code_point.between?(0xE000, 0x10000)
        aligned_low = code_point % 0x80
        selector = 0x68 + (code_point - 0xE000) / 0x80
        if selector <= 0xA6 &&
           (aligned_low.between?(0x20, 0x7F) ||
            aligned_low.between?(0xA0, 0xFF))
          return [0x68 + (code_point - 0xE000) / 0x80, aligned_low]
        end
      end
      if code_point < 0x3400
        selector = code_point / 0x80 + 1
        low = code_point % 0x80
        return [selector, low] if selector.between?(0x01, 0x67) &&
                                  (low.between?(0x20, 0x7F) ||
                                   low.between?(0xA0, 0xFF))
      elsif code_point.between?(0xE000, 0xFF80)
        selector = 0x68 + (code_point - 0xE000) / 0x80
        low = code_point % 0x80
        return [selector, low] if selector.between?(0x68, 0xA6) &&
                                  (low.between?(0x20, 0x7F) ||
                                   low.between?(0xA0, 0xFF))
      end
      SPECIAL_DYNAMIC_OFFSETS.each do |selector, offset|
        low = code_point - offset
        return [selector, low] if low.between?(0x20, 0x7F)
        return [selector, low | 0x80] if low.between?(0xA0, 0xFF)
      end
      nil
    end

    def self.encode(string)
      unless string.is_a?(String) &&
             (string.encoding == Encoding::UTF_8 ||
              string.encoding == Encoding::US_ASCII ||
              string.encoding == Encoding::UTF_16 ||
              string.encoding == Encoding::UTF_32)
        raise ArgumentError, "input must be a Unicode string"
      end

      output = String.new.force_encoding(Encoding::BINARY)
      offsets = INITIAL_DYNAMIC_OFFSETS.dup
      active = 0
      next_window = 7
      mode = :single
      code_points = string.to_enum(:each_codepoint).to_a
      index = 0

      while index < code_points.length
        code_point = code_points[index]
        unless code_point.between?(0, 0x10FFFF) && !(code_point.between?(0xD800, 0xDFFF))
          raise InvalidEncoding, "not a Unicode scalar value: #{code_point}"
        end

        if mode == :unicode
          if code_point <= 0x00 ||
             code_point.between?(0x09, 0x0D) ||
             code_point.between?(0x20, 0xFF)
            output << 0x0F
            mode = :single
            next
          end
          if code_point <= 0xFFFF
            append_utf16_unit(output, code_point)
          else
            append_utf16_unit(output, 0xD7C0 + (code_point >> 10))
            append_utf16_unit(output, 0xDC00 + (code_point & 0x3FF))
          end
          index += 1
          next
        end

        if code_point == 0x0E || code_point == 0x0F ||
           code_point.between?(0x10, 0x1F)
          output << 0x0E
          append_utf16_unit(output, code_point)
          index += 1
          next
        end

        quoted_static = static_quote(code_point)

        offset = offsets[active]
        low = code_point - offset
        if low.between?(0x20, 0x7F) || low.between?(0x80, 0xFF)
          output << low
          index += 1
          next
        end

        existing = existing_dynamic_window(offsets, code_point)
        quoted_dynamic = dynamic_quote(offsets, code_point)

        run_length = 0
        run_length += 1 while unicode_run_member?(code_points[index + run_length])

        selector, low = dynamic_position(code_point)
        if selector && (low.between?(0x20, 0x7F) || low.between?(0xA0, 0xFF)) &&
           run_length >= 2
          window_index = next_window
          next_window = (next_window + 1) % 8
          offsets[window_index] = dynamic_offset(selector)
          output << (0x18 + window_index)
          output << selector
          output << low
          active = window_index
        elsif existing
          window_index, low = existing
          output << (0x10 + window_index)
          output << low
        elsif quoted_static && quoted_static.last <= 0x7F && run_length >= 2
          selector, low = dynamic_position(code_point)
          if selector && (low.between?(0x20, 0x7F) || low.between?(0xA0, 0xFF))
            window_index = next_window
            next_window = (next_window + 1) % 8
            offsets[window_index] = dynamic_offset(selector)
            output << (0x18 + window_index)
            output << selector
            output << low
            active = window_index
          else
            output << (0x01 + quoted_static.first)
            output << quoted_static.last
          end
        elsif run_length >= 2
          output << 0x0F
          while run_length > 0
            point = code_points[index]
            if point <= 0xFFFF
              append_utf16_unit(output, point)
            else
              append_utf16_unit(output, 0xD7C0 + (point >> 10))
              append_utf16_unit(output, 0xDC00 + (point & 0x3FF))
            end
            index += 1
            run_length -= 1
          end
          mode = :unicode
          next
        elsif quoted_dynamic
          window_index, low = quoted_dynamic
          output << (0x10 + window_index)
          output << low
        elsif quoted_static
          output << (0x01 + quoted_static.first)
          output << quoted_static.last
        else
          output << 0x0E
          if code_point <= 0xFFFF
            append_utf16_unit(output, code_point)
          else
            append_utf16_unit(output, 0xD7C0 + (code_point >> 10))
            output << 0x0E
            append_utf16_unit(output, 0xDC00 + (code_point & 0x3FF))
          end
        end

        index += 1
      end

      output
    end

    def self.decode(string)
      decoder = Decoder.new
      result = decoder.feed(string)
      result << decoder.finish
      result
    end

    class Decoder
      def initialize
        @offsets = INITIAL_DYNAMIC_OFFSETS.dup
        @active = 0
        @mode = :single
        @pending_high_byte = nil
        @pending_quoted_unit = false
        @high_surrogate = nil
        @pending_tag = nil
        @finished = false
      end

      def feed(input)
        raise ArgumentError, "input must be a String" unless input.is_a?(String)
        raise InvalidEncoding, "decoder is finished" if @finished

        @result = String.new.force_encoding(Encoding::UTF_8)
        input.each_byte { |byte| process_byte(byte) }
        @result
      end

      def finish
        @finished = true
        if @mode == :unicode && !@pending_high_byte.nil? && @pending_tag.nil?
          unicode_unit(@pending_high_byte)
          @pending_high_byte = nil
        end
        error = @pending_high_byte || @pending_tag || @high_surrogate || @pending_quoted_unit
        raise InvalidEncoding, "incomplete SCSU sequence" if error
        String.new.force_encoding(Encoding::UTF_8)
      end

      private

      def process_byte(byte)
        if !@pending_high_byte.nil?
          unit = (@pending_high_byte << 8) | byte
          @pending_high_byte = nil
          if @pending_quoted_unit
            @pending_quoted_unit = false
            was_quoted_unit = true
            quoted_from_single_mode = @mode == :single
            @pending_tag = nil
          else
            was_quoted_unit = false
            quoted_from_single_mode = false
          end
          if was_quoted_unit
            surrogate_unit(unit)
            if quoted_from_single_mode
              @mode = :single if !@high_surrogate || unit.between?(0xDC00, 0xDFFF)
            end
          else
            unicode_unit(unit)
          end
        elsif @mode == :single
          single_byte(byte)
        else
          @pending_high_byte = byte
        end
      end

      def single_byte(byte)
        if !@pending_tag.nil?
          tag = @pending_tag
          @pending_tag = nil
          if tag == :quote_unicode
            if @pending_high_byte.nil?
              @pending_high_byte = byte
              @pending_quoted_unit = true
            else
              unit = (@pending_high_byte << 8) | byte
              @pending_high_byte = nil
              surrogate_unit(unit)
            end
          elsif tag.is_a?(Integer) && tag.between?(0x01, 0x08)
            emit_code_point(STATIC_OFFSETS[tag - 1] + (byte & 0x7F))
          elsif tag.is_a?(Integer) && tag.between?(0x10, 0x17)
            @active = tag - 0x10
            single_text(byte)
          else
            offset = SCSU.dynamic_offset(byte)
            raise InvalidEncoding, "reserved dynamic window selector" unless offset
            index = tag - 0x18
            @offsets[index] = offset
            @active = index
          end
        else
          if byte <= 0x00 || byte.between?(0x09, 0x0D)
            emit_code_point(byte)
          elsif byte == 0x0E
            @pending_tag = :quote_unicode
          elsif byte == 0x0F
            @mode = :unicode
          elsif byte.between?(0x01, 0x08) || byte.between?(0x10, 0x1F)
            @pending_tag = byte
          else
            single_text(byte)
          end
        end
      end

      def single_text(byte)
        emit_code_point(@offsets[@active] + byte)
      end

      def unicode_unit(unit)
        if @pending_tag == :quote_unicode
          @pending_tag = nil
          surrogate_unit(unit)
        elsif unit == 0x0F
          @mode = :single
        else
          surrogate_unit(unit)
        end
      end

      def surrogate_unit(unit)
        if @high_surrogate
          unless unit.between?(0xDC00, 0xDFFF)
            raise InvalidEncoding, "unpaired UTF-16 surrogate"
          end
          point = 0x10000 + (@high_surrogate - 0xD800) * 0x400 + (unit - 0xDC00)
          @high_surrogate = nil
          emit_code_point(point)
        elsif unit.between?(0xD800, 0xDBFF)
          @high_surrogate = unit
        elsif unit.between?(0xDC00, 0xDFFF)
          raise InvalidEncoding, "unexpected low surrogate"
        else
          emit_code_point(unit)
        end
      end

      def emit_code_point(point)
        unless point.between?(0, 0x10FFFF) && !point.between?(0xD800, 0xDFFF)
          raise InvalidEncoding, "invalid code point U+#{point.to_s(16).upcase}"
        end
        @result << point.chr(Encoding::UTF_8)
      end
    end

    def self.static_quote(code_point)
      STATIC_OFFSETS.each_with_index do |offset, index|
        low = code_point - offset
        return [index, low] if low.between?(0x00, 0x7F)
      end
      nil
    end

    def self.dynamic_quote(offsets, code_point)
      offsets.each_with_index do |offset, index|
        low = code_point - offset
        return [index, low | 0x80] if low.between?(0x00, 0x1F)
        return [index, low] if low.between?(0x20, 0x7F)
      end
      nil
    end

    def self.existing_dynamic_window(offsets, code_point)
      offsets.each_with_index do |offset, index|
        low = code_point - offset
        if low.between?(0x20, 0x7F) || low.between?(0xA0, 0xFF)
          return [index, low]
        end
      end
      nil
    end

    def self.unicode_run_member?(code_point)
      return false unless code_point
      selector, low = dynamic_position(code_point)
      return false if code_point < 0x20 || static_quote(code_point)
      return true unless selector
      low.between?(0x20, 0x7F) || low.between?(0xA0, 0xFF)
    end

    def self.append_utf16_unit(output, unit)
      output << (unit >> 8)
      output << (unit & 0xFF)
    end

    private_class_method :static_quote, :dynamic_quote,
                         :existing_dynamic_window, :unicode_run_member?,
                         :append_utf16_unit

  end

  def scsu_encode(string)
    SCSU.encode(string)
  end
  module_function :scsu_encode

  def scsu_decode(string)
    SCSU.decode(string)
  end
  module_function :scsu_decode

end
