# -*- encoding: utf-8 -*-

require "unicode_utils/read_cdata"

module UnicodeUtils

  # An ICU compatible subset of UnicodeSet patterns.
  #
  # Supported syntax:
  #
  # - code points and ranges: <tt>[a-z \x{20AC}]</tt>
  # - escaped set metacharacters: <tt>[\[\]\-\&\{\}]</tt>
  # - multi-code-point string elements: <tt>[{ch} {a\-b}]</tt>
  # - nested sets with union, intersection and difference:
  #   <tt>[[a-z] & [a-c] - [b]]</tt>
  # - top level complement: <tt>[^a-z{ch}]</tt>
  # - binary and general category properties:
  #   <tt>[\p{Letter} \p{White_Space} \P{Lu}]</tt>
  #
  # Property aliases are resolved with Unicode 6.2.0. Supported properties
  # are General_Category values and the binary properties from PropList
  # and DerivedCoreProperties. A string enclosed in braces is one element;
  # it is never split into individual code points. Complement only applies
  # to the code point part of a set, while explicit string elements are
  # retained.
  class UnicodeSet

    UNICODE_VERSION = "6.2.0"

    CODE_POINT_RANGE = 0..0x10FFFF

    def initialize(intervals = [], strings = [], complemented = false)
      @intervals = Impl.normalize_intervals(intervals)
      @strings = strings.uniq.sort.freeze
      @complemented = complemented
    end

    # Parse an ICU UnicodeSet pattern subset and return a UnicodeSet.
    def self.parse(pattern)
      Parser.new(pattern).parse!
    end

    # Return true if a single code point or an explicit string element is
    # included. A multi-code-point string is only included if the complete
    # string was added inside braces.
    def include?(object)
      case object
      when Integer
        code_point_include?(object)
      when String
        if object.length == 1
          code_point_include?(object.ord)
        else
          @strings.include?(object)
        end
      else
        object.respond_to?(:ord) && code_point_include?(object.ord)
      end
    end

    alias member? include?
    alias contains? include?

    # Return true for [^...].
    def complemented?
      @complemented
    end

    # Return the canonical UnicodeSet pattern.
    def to_s
      io = ["["]
      io << "^" if @complemented
      printable_intervals.each do |range|
        io << format_code_point_token(range.begin)
        if range.begin != range.end
          io << "-"
          io << format_code_point_token(range.end)
        end
      end
      @strings.each { |string| io << format_string(string) }
      io << "]"
      io.join
    end

    alias to_str to_s
    alias inspect to_s

    def ==(other)
      other.is_a?(UnicodeSet) &&
        complemented? == other.complemented? &&
        to_a == other.to_a &&
        strings == other.strings
    end
    alias eql? ==

    def hash
      [@complemented, @intervals, @strings].hash
    end

    # Return normalized code point ranges.
    def to_a
      @intervals.dup
    end

    protected

    attr_reader :strings

    def printable_intervals
      @intervals.dup
    end

    def code_point_include?(code_point)
      return false unless CODE_POINT_RANGE.include?(code_point)
      contained = @intervals.any? { |range| range.include?(code_point) }
      @complemented ? !contained : contained
    end

    def format_code_point(code_point)
      if code_point <= 0xFFFF
        sprintf("%04X", code_point)
      else
        sprintf("%X", code_point)
      end
    end

    def format_code_point_token(code_point)
      return "\\-" if code_point == 0x2D
      return "\\x{#{format_code_point(code_point)}}" if code_point > 0xFFFF
      char = literal_code_point(code_point)
      return char if char
      case code_point
      when 0x09 then "\\t"
      when 0x0A then "\\n"
      when 0x0D then "\\r"
      else "\\x{#{format_code_point(code_point)}}"
      end
    end

    def format_string(string)
      formatted = string.gsub(/[\\}]/) { |char| "\\#{char}" }
      "{#{formatted}}"
    end

    def literal_code_point(code_point)
      return nil if code_point < 0x20 || code_point == 0x7F ||
                    (0x80..0x9F).include?(code_point) ||
                    (0xD800..0xDFFF).include?(code_point)
      char = [code_point].pack("U")
      return nil if char =~ /\s/
      return nil if char =~ /[\[\]&\-{}u]/
      char
    end

    class Parser

      def initialize(pattern)
        @pattern = pattern.to_str.dup.force_encoding(Encoding::UTF_8)
        @index = 0
      end

      def parse!
        read_char("[")
        @range_candidate = false
        @space_before_dash = false
        complemented = skip("^")
        set = parse_sequence("]")
        read_char("]")
        raise ArgumentError, "extra data after UnicodeSet" unless end?
        UnicodeSet.new(set[0], set[1], complemented)
      end

      private

      def parse_sequence(stop)
        skip_pattern_whitespace
        return [[], []] if peek == stop
        @space_before_dash = false
        set = parse_term
        while !end? && peek != stop
          operator_position = @index
          @space_before_dash = false
          skip_pattern_whitespace
          break if end? || peek == stop
          @space_before_dash =
            operator_position != @index && peek == "-"
          operator = read_operator
          skip_pattern_whitespace
          right = parse_term
          set =
            case operator
            when :intersection
              Impl.intersect_sets(set, right)
            when :difference
              Impl.subtract_sets(set, right)
            else
              Impl.union_sets(set, right)
            end
        end
        set
      end

      def read_operator
        operator =
          if peek == "&"
            :intersection
          elsif peek == "-" && set_difference_operator?
            :difference
          else
            :union
          end
        skip("&") if operator == :intersection
        skip("-") if operator == :difference
        operator
      end

      def set_difference_operator?
        return true unless @range_candidate
        return true if @space_before_dash
        next_index = @index + 1
        next_index += 1 while next_index < @pattern.length && @pattern[next_index] =~ /\s/
        return false if next_index >= @pattern.length
        next_char = @pattern[next_index]
        return true if next_char == "[" || next_char == "{"
        if next_char == "\\"
          escape_index = next_index + 1
          return false if escape_index >= @pattern.length
          property_char = @pattern[escape_index]
          return true if property_char == "p" || property_char == "P"
          property_index = escape_index
          if property_char == "x" || property_char == "u" || property_char == "U"
            return false
          end
          return false
        end
        false
      end

      def parse_term
        if skip("[")
          complemented = skip("^")
          set = parse_sequence("]")
          read_char("]")
          set = Impl.complement_set(set) if complemented
          @range_candidate = false
          set
        elsif skip("\\")
          read_escaped_term
        elsif skip("{")
          @inside_string = true
          read_string_term
        else
          read_literal_term
        end
      end

      def read_escaped_term
        char = read_escape
        if char == "p" || char == "P"
          braced = skip("{")
          property = braced ? read_until("}") : read_inline_property
          read_char("}") if braced
          set = Impl.property_set(property)
          @range_candidate = false
          char == "P" ? Impl.complement_set(set) : set
        else
          extend_char_term(char)
        end
      end

      def read_string_term
        string = read_quoted_string
        read_char("}")
        @inside_string = false
        @range_candidate = false
        [[], [string]]
      end

      def read_literal_term
        char = read_unescaped_char
        extend_char_term(char)
      end

      def extend_char_term(char)
        first = char.ord
        if range_operator?
          @index += 1
          @range_candidate = false
          second = read_endpoint
          raise ArgumentError, "empty code point range" if second < first
          [[first..second], []]
        else
          @range_candidate = true
          [[first..first], []]
        end
      end

      def read_endpoint
        if skip("\\")
          read_escape.ord
        else
          read_unescaped_char.ord
        end
      end

      def range_operator?
        return false if @inside_string
        return false unless peek == "-"
        return false if @space_before_dash
        next_index = @index + 1
        return false if next_index >= @pattern.length
        @pattern[next_index] !~ /[\[\]&\\{]/
      end

      def read_quoted_string
        chars = []
        until end? || peek == "}"
          if skip("\\")
            chars << read_escape
          else
            chars << read_unescaped_char
          end
        end
        chars.join
      end

      def read_until(stop)
        start = position
        until end? || peek == stop
          @index += 1
        end
        @pattern[start...@index].force_encoding(Encoding::UTF_8)
      end

      def read_inline_property
        start = position
        until end? || peek =~ /[\[\]&\-]/
          @index += 1
        end
        @pattern[start...@index].strip
      end

      def read_escape
        raise ArgumentError, "expected escape" if end?
        char = read_one
        case char
        when "x"
          read_char("{")
          hex = read_until("}")
          read_char("}")
          hex_to_char(hex)
        when "u"
          hex = read_hex(4)
          hex_to_char(hex)
        when "U"
          hex = read_hex(8)
          hex_to_char(hex)
        when "n" then "\n"
        when "r" then "\r"
        when "t" then "\t"
        when "f" then "\f"
        when "a" then "\a"
        when "e" then "\e"
        when "v" then "\v"
        when "0".."7" then read_octal(char)
        else char
        end
      end

      def read_octal(first)
        digits = first
        2.times do
          break if end? || peek !~ /[0-7]/
          digits << read_one
        end
        [digits.to_i(8)].pack("U")
      end

      def read_hex(length)
        hex = ""
        length.times do
          char = read_one
          raise ArgumentError, "expected hex digit" unless char =~ /[0-9A-Fa-f]/
          hex << char
        end
        hex
      end

      def hex_to_char(hex)
        value = Integer(hex, 16)
        unless UnicodeSet::CODE_POINT_RANGE.include?(value)
          raise ArgumentError, "code point outside Unicode codespace"
        end
        [value].pack("U")
      end

      def read_unescaped_char
        char = read_one
        if char == "\\"
          read_escape
        elsif char =~ /[\[\]&]/
          raise ArgumentError, "unexpected #{char.inspect}"
        else
          char
        end
      end

      def read_char(expected)
        raise ArgumentError, "expected #{expected.inspect}" unless skip(expected)
      end

      def skip(expected)
        if peek == expected
          @index += 1
          true
        else
          false
        end
      end

      def peek
        return nil if end?
        @pattern[@index]
      end

      def read_one
        char = peek
        raise ArgumentError, "unexpected end of UnicodeSet" unless char
        @index += 1
        char
      end

      def position
        @index
      end

      def end?
        @index >= @pattern.bytesize
      end

      def skip_pattern_whitespace
        had_whitespace = false
        while !end? && peek =~ /\s/
          had_whitespace = true
          @index += 1
        end
        @space_before_dash = had_whitespace
      end

    end

    module Impl

      PROPERTY_CACHE = {}

      def self.normalize_intervals(intervals)
        sorted = intervals.map { |range| Range.new(range.begin, range.end) }.
          sort_by(&:begin)
        sorted.each_with_object([]) do |range, result|
          if result.empty? || range.begin > result.last.end
            result << range
          else
            result[-1] = (result.last.begin..[result.last.end, range.end].max)
          end
        end
      end

      def self.union_sets(left, right)
        [normalize_intervals(left[0] + right[0]), (left[1] + right[1]).uniq.sort]
      end

      def self.intersect_sets(left, right)
        intervals = []
        left[0].each do |left_range|
          right[0].each do |right_range|
            first = [left_range.begin, right_range.begin].max
            last = [left_range.end, right_range.end].min
            intervals << (first..last) if first <= last
          end
        end
        [normalize_intervals(intervals), left[1] & right[1]]
      end

      def self.subtract_sets(left, right)
        intervals = left[0].dup
        right[0].each do |removed|
          intervals = intervals.flat_map do |range|
            next [range] if removed.end < range.begin || removed.begin > range.end
            parts = []
            parts << (range.begin..removed.begin - 1) if range.begin < removed.begin
            parts << (removed.end + 1..range.end) if removed.end < range.end
            parts
          end
        end
        [normalize_intervals(intervals), left[1] - right[1]]
      end

      def self.complement_set(set)
        [subtract_intervals([[0, 0x10FFFF]], set[0]), set[1]]
      end

      def self.property_set(name)
        key = loose_property_name(name)
        PROPERTY_CACHE[key] ||= load_property_set(name.to_str)
      end

      def self.loose_property_name(name)
        name.to_str.gsub(/[\s_\-]+/, "").downcase
      end

      def self.load_property_set(original_name)
        property_name, value = original_name.split(/[=:]/, 2)
        property_name = property_name && property_name.strip
        value = value && value.strip
        normalized_property = loose_property_name(property_name || "")
        normalized_value = value && loose_property_name(value)

        case normalized_property.empty? ? normalized_value : normalized_property
        when "any"
          return [[0..0x10FFFF], []]
        when "ascii"
          return [[0..0x7F], []]
        when "assigned"
          return [subtract_intervals([[0, 0x10FFFF]], named_property_intervals("cn")), []]
        end

        lookup =
          if property_name && value
            if normalized_property == "gc" || normalized_property == "generalcategory"
              normalized_value
            elsif %w[t true y yes].include?(normalized_value)
              normalized_property
            elsif %w[f false n no].include?(normalized_value)
              ""
            else
              raise ArgumentError, "unsupported Unicode property"
            end
          else
            normalized_property
          end

        return [[], []] if lookup.empty?

        intervals = named_property_intervals(lookup)
        if intervals
          return [intervals, []]
        end

        raise ArgumentError, "unsupported Unicode property"
      end

      def self.named_property_intervals(name)
        property_index[name]
      end

      def self.property_index
        @property_index ||= begin
          index = {}
          path = File.join(CDATA_DIR, "unicode_set_properties")
          File.open(path, "r:UTF-8") do |input|
            input.each_line do |line|
              next if line.start_with?("#") || line.strip.empty?
              range_line = input.gets
              intervals = range_line.split.map do |token|
                first, last = token.split("-")
                (first.to_i(16)..(last || first).to_i(16))
              end
              line.chomp.split(",").each do |name|
                index[loose_property_name(name)] = intervals
              end
            end
          end
          index
        end
      end

      def self.subtract_intervals(left, right)
        left.map { |first, last| (first..last) }.flat_map do |range|
          remaining = [range]
          right.each do |removed|
            remaining = remaining.flat_map do |current|
              next [current] if removed.end < current.begin || removed.begin > current.end
              parts = []
              parts << (current.begin..removed.begin - 1) if current.begin < removed.begin
              parts << (removed.end + 1..current.end) if removed.end < current.end
              parts
            end
          end
          remaining
        end
      end

    end

  end

end
