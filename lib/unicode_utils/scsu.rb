# -*- encoding: utf-8 -*-

module UnicodeUtils

  # Encode and decode Unicode text with the Standard Compression Scheme
  # for Unicode (SCSU, UTS #6).
  #
  #   require "unicode_utils/scsu"
  #   bytes = UnicodeUtils::SCSU.encode("ελληνικά")
  #   UnicodeUtils::SCSU.decode(bytes) => "ελληνικά"
  #
  # Encoder and Decoder both expose #feed and #finish for streaming use.
  module SCSU

    SQ0 = 0x01
    SQ7 = 0x08
    SDX = 0x0B
    SQU = 0x0E
    SCU = 0x0F
    SD0 = 0x10
    SD7 = 0x17
    UQU = 0x0E
    UCU = 0x9F
    UD0 = 0x90
    UD7 = 0x97
    UDX = 0x9B

    STATIC_OFFSETS = [
      0x0000, 0x0080, 0x0100, 0x0300, 0x2000, 0x2080,
      0x2100, 0x3000
    ].freeze

    INITIAL_OFFSETS = STATIC_OFFSETS.dup.freeze

    DYNAMIC_OFFSETS = (
      (0x0080..0x3380).step(0x80).to_a +
      (0xE000..0xFF80).step(0x80).to_a +
      (0x00C0..0x0240).step(0x40).to_a +
      (0x3400..0x37C0).step(0x40).to_a +
      (0x3040..0x30F0).step(0x10).to_a +
      (0x10000...0x11700).step(0x80).to_a +
      (0x103000...0x103400).step(0x80).to_a
    ).freeze

    class EncodingError < StandardError; end
    class DecodingError < StandardError; end

    def self.encode(str)
      encoder = Encoder.new
      encoder.feed(str.to_str) + encoder.finish
    end

    def self.decode(bytes)
      decoder = Decoder.new
      decoder.feed(bytes.to_str) + decoder.finish
    end

    # Stateful SCSU encoder. Calls to #feed may receive arbitrary UTF-8
    # chunks; multibyte code points are retained until complete.
    class Encoder
      def initialize
        @windows = INITIAL_OFFSETS.dup
        @active_window = 0
        @unicode_mode = false
        @next_window = 1
        @pending = String.new(encoding: Encoding::BINARY)
      end

      def feed(str)
        str = str.to_str
        str = str.encode(Encoding::UTF_8) unless str.encoding.equal?(Encoding::UTF_8)
        @pending << str.b
        out = String.new(encoding: Encoding::BINARY)
        extract_codepoints.each { |point| encode_point(point, out) }
        out
      end

      def finish
        unless @pending.bytesize.zero?
          raise EncodingError, "incomplete UTF-8 sequence"
        end
        String.new(encoding: Encoding::BINARY)
      end

      private

      def extract_codepoints
        bytes = @pending.bytes
        points = []
        index = 0

        while index < bytes.length
          byte = bytes[index]
          width = utf8_width(byte)
          break if width.nil? || index + width > bytes.length

          point = utf8_start_value(byte, width)
          valid = true
          (1...width).each do |offset|
            continuation = bytes[index + offset]
            unless continuation >> 6 == 0x02
              valid = false
              break
            end
            point = (point << 6) | (continuation & 0x3F)
          end

          minimum = width == 1 ? 0x00 :
                    width == 2 ? 0x80 :
                    width == 3 ? 0x800 : 0x10000
          unless valid && point >= minimum && valid_scalar?(point)
            raise EncodingError, "invalid Unicode scalar value"
          end

          points << point
          index += width
        end

        @pending = bytes[index..-1].pack("C*").force_encoding(Encoding::BINARY)
        points
      end

      def utf8_width(byte)
        if byte < 0x80
          1
        elsif byte >> 5 == 0x06
          2
        elsif byte >> 4 == 0x0E
          3
        elsif byte >> 3 == 0x1E
          4
        end
      end

      def utf8_start_value(byte, width)
        case width
        when 1 then byte
        when 2 then byte & 0x1F
        when 3 then byte & 0x0F
        else byte & 0x07
        end
      end

      def encode_point(point, out)
        if point < 0x80
          emit_ascii(point, out)
          return
        end
        static = STATIC_OFFSETS.each_index.detect do |slot|
          point >= STATIC_OFFSETS[slot] && point < STATIC_OFFSETS[slot] + 0x20
        end
        cached = @windows.each_index.detect do |slot|
          point - @windows[slot] >= 0x20 && in_window?(@windows[slot], point)
        end
        if cached
          emit_dynamic(point, cached, out)
          return
        end

        if static
          emit_static(point, static, out)
          return
        end

        selector = DYNAMIC_OFFSETS.each_index.detect do |candidate|
          point - DYNAMIC_OFFSETS[candidate] >= 0x20 &&
            in_window?(DYNAMIC_OFFSETS[candidate], point)
        end

        if selector
          slot = choose_window(selector)
          define_window(slot, selector, out)
          @windows[slot] = DYNAMIC_OFFSETS[selector]
          if @unicode_mode
            out << UCU
            @unicode_mode = false
          end
          emit_dynamic(point, slot, out)
        else
          emit_unicode(point, out)
        end
      end

      def choose_window(selector)
        existing = @windows.index(DYNAMIC_OFFSETS[selector])
        return existing if existing && existing != 0
        slot = @next_window
        @next_window = (@next_window % 7) + 1
        slot
      end

      def define_window(slot, selector, out)
        tag = @unicode_mode ? UD0 : SD0
        out << (tag + slot) << selector
        @active_window = slot
      end

      def emit_dynamic(point, slot, out)
        enter_single_mode(out)
        relative = point - @windows[slot]
        payload = dynamic_byte(relative)
        if slot == @active_window && payload >= 0x20 && payload < 0x98
          out << dynamic_byte(relative)
        else
          out << (SQ0 + slot) << quoted_dynamic_byte(relative)
        end
      end

      def emit_static(point, slot, out)
        enter_single_mode(out)
        payload = point - STATIC_OFFSETS[slot]
        if slot == @active_window
          out << payload
        else
          out << (SQ0 + slot) << payload
        end
      end

      def emit_ascii(point, out)
        enter_single_mode(out)
        if @active_window == 0
          out << (point + 0x80)
        else
          out << SQ0 << (point + 0x80)
        end
      end

      def dynamic_byte(relative)
        if relative < 0x60
          relative + 0x20
        else
          relative + 0x80
        end
      end

      def quoted_dynamic_byte(relative)
        if relative < 0xE0
          dynamic_byte(relative)
        else
          relative - 0xE0
        end
      end

      def enter_single_mode(out)
        return unless @unicode_mode
        out << UCU
        @unicode_mode = false
      end

      def emit_unicode(point, out)
        unless @unicode_mode
          out << SCU
          @unicode_mode = true
        end

        if point <= 0xFFFF
          high = point >> 8
          if high <= 0x1F || (high >= 0x90 && high <= 0x9F)
            out << UQU
            out_utf16_unit(point, out)
          else
            out_utf16_unit(point, out)
          end
        else
          value = point - 0x10000
          out << UQU
          out_utf16_unit(0xD800 + (value >> 10), out)
          out_utf16_unit(0xDC00 + (value & 0x3FF), out)
        end
      end

      def out_utf16_unit(unit, out)
        out << (unit >> 8) << (unit & 0xFF)
      end

      def in_window?(offset, point)
        point >= offset && point < offset + 0x80
      end

      def valid_scalar?(point)
        point <= 0x10FFFF && !surrogate?(point)
      end

      def surrogate?(point)
        point >= 0xD800 && point <= 0xDFFF
      end
    end

    # Stateful SCSU decoder. Both #feed and #finish return decoded UTF-8.
    class Decoder
      def initialize
        reset
      end

      def feed(input)
        @byte_buffer << input.to_str.b
        bytes = @byte_buffer.bytes
        out = String.new(encoding: Encoding::UTF_8)
        index = 0
        pending_index = index

        while index < bytes.length
          pending_index = index
          if @quoted_window
            pending_index = @pending_start
            index = decode_quoted(bytes, index, out)
            unless index.nil?
              @quoted_window = nil
              @pending_start = 0
            end
          elsif @unicode_quote
            pending_index = @pending_start
            index = decode_unicode_quote(bytes, index, out)
          elsif @unicode_mode
            index = decode_unicode_byte(bytes, index, out)
            if @mode_changed
              pending_index = index
              @mode_changed = false
            end
          else
            index = decode_single_byte(bytes, index, out)
          end
          break if index.nil?
        end

        consumed = index || pending_index
        remainder = bytes[consumed..-1]
        @byte_buffer = (remainder || []).pack("C*").force_encoding(Encoding::BINARY)
        out
      end

      def finish
        unless @byte_buffer.bytesize.zero?
          raise DecodingError, "incomplete SCSU sequence"
        end
        reject_pending_surrogate
        String.new(encoding: Encoding::UTF_8)
      end

      private

      def reset
        @windows = INITIAL_OFFSETS.dup
        @active_window = 0
        @unicode_mode = false
        @quoted_window = nil
        @pending_start = 0
        @unicode_quote = nil
        @pending_surrogate = nil
        @mode_changed = false
        @byte_buffer = String.new(encoding: Encoding::BINARY)
      end

      def decode_single_byte(bytes, index, out)
        byte = bytes[index]

        if byte == SCU
          @unicode_mode = true
          return index + 1
        elsif byte == SQU
          if index + 3 > bytes.length
            @unicode_quote = index + 1 < bytes.length ? [bytes[index + 1]] : []
            @pending_start = index
            return nil
          end
          unit = (bytes[index + 1] * 256) + bytes[index + 2]
          emit_unicode_unit(unit, out)
          index + 3
        elsif byte == SDX
          return read_extended_window(bytes, index, true)
        elsif byte >= SD0 && byte <= SD7
          return read_dynamic_window(bytes, index, byte - SD0)
        elsif byte >= SQ0 && byte <= SQ7
          return nil if index + 1 >= bytes.length
          @quoted_window = byte - SQ0
          @pending_start = index
          index + 1
        elsif byte == 0x18 || byte == 0x19
          raise DecodingError, "reserved SCSU command byte #{byte.to_s(16)}"
        else
          emit_single_byte(byte, @active_window, out)
          index + 1
        end
      end

      def decode_quoted(bytes, index, out)
        byte = bytes[index]
        reject_pending_surrogate if @unicode_mode
        if byte < 0x20
          append_point(STATIC_OFFSETS[@quoted_window] + byte, out)
        else
          emit_single_byte(byte, @quoted_window, out)
        end
        index + 1
      end

      def decode_unicode_quote(bytes, index, out)
        @unicode_quote << bytes[index]
        return nil if @unicode_quote.length < 2
        first, second = @unicode_quote
        unit = (first * 256) + second
        @unicode_quote = nil
        @pending_start = 0
        emit_unicode_unit(unit, out)
        index + 1
      end

      def decode_unicode_byte(bytes, index, out)
        byte = bytes[index]

        if byte == UCU
          reject_pending_surrogate
          @unicode_mode = false
          @mode_changed = true
          index + 1
        elsif byte >= 0x80
          if byte == UDX
            read_extended_window(bytes, index, false)
          elsif byte >= UD0 && byte <= UD7
            read_dynamic_window(bytes, index, byte - UD0)
          elsif byte == 0x9A || byte == 0x9C || byte == 0x9D || byte == 0x9E
            raise DecodingError, "reserved SCSU command byte #{byte.to_s(16)}"
          else
            return nil if index + 1 >= bytes.length
            emit_unicode_unit((byte << 8) | bytes[index + 1], out)
            index + 2
          end
        elsif byte == UQU
          if index + 3 > bytes.length
            @pending_start = index
            return nil
          end
          emit_unicode_unit((bytes[index + 1] * 256) + bytes[index + 2], out)
          index + 3
        elsif byte >= SQ0 && byte <= SQ7
          return nil if index + 1 >= bytes.length
          reject_pending_surrogate
          @quoted_window = byte - SQ0
          @pending_start = index
          index + 1
        else
          return nil if index + 1 >= bytes.length
          emit_unicode_unit((byte << 8) | bytes[index + 1], out)
          index + 2
        end
      end

      def read_dynamic_window(bytes, index, slot)
        return nil if index + 1 >= bytes.length
        reject_pending_surrogate
        selector = bytes[index + 1]
        unless selector < DYNAMIC_OFFSETS.length
          raise DecodingError, "invalid dynamic window selector #{selector}"
        end
        @windows[slot] = DYNAMIC_OFFSETS[selector]
        @active_window = slot
        index + 2
      end

      def read_extended_window(bytes, index, remain_single)
        return nil if index + 1 >= bytes.length
        return nil if index + 2 >= bytes.length
        reject_pending_surrogate
        first = bytes[index + 1]
        second = bytes[index + 2]
        if first > 0x7F || second > 0x7F
          raise DecodingError, "invalid extended window selector"
        end
        @windows[@active_window] = ((first << 8) | second) << 7
        @unicode_mode = false unless remain_single
        index + 3
      end

      def emit_single_byte(byte, slot, out)
        point = if byte < 0x20
                  STATIC_OFFSETS[slot] + byte
                elsif byte < 0x80
                  @windows[slot] + byte - 0x20
                else
                  @windows[slot] + byte - 0x80
                end
        append_point(point, out)
      end

      def emit_unicode_unit(unit, out)
        if @pending_surrogate
          unless unit >= 0xDC00 && unit <= 0xDFFF
            raise DecodingError, "unpaired UTF-16 surrogate"
          end
          point = 0x10000 + (@pending_surrogate - 0xD800) * 0x400 +
                  (unit - 0xDC00)
          @pending_surrogate = nil
          append_point(point, out)
        elsif unit >= 0xD800 && unit <= 0xDBFF
          @pending_surrogate = unit
        elsif unit >= 0xDC00 && unit <= 0xDFFF
          raise DecodingError, "unpaired UTF-16 surrogate"
        else
          append_point(unit, out)
        end
      end

      def reject_pending_surrogate
        return unless @pending_surrogate
        raise DecodingError, "unpaired UTF-16 surrogate"
      end

      def append_point(point, out)
        if point > 0x10FFFF || (point >= 0xD800 && point <= 0xDFFF)
          raise DecodingError, "invalid Unicode scalar value U+#{point.to_s(16)}"
        end
        out << point.chr(Encoding::UTF_8)
      end
    end
  end
end
