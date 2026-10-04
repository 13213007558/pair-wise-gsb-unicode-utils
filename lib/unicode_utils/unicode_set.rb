# -*- encoding: utf-8 -*-

require "strscan"
require "unicode_utils/read_cdata"
require "unicode_utils/version"

module UnicodeUtils

  # A parsed ICU compatible subset of a UnicodeSet pattern.
  #
  # This implementation is fixed to UnicodeUtils::UNICODE_VERSION (currently
  # Unicode 6.2.0). Property and property-value aliases are resolved from
  # that Unicode version, independently of the Ruby version.
  #
  # The documented subset supports code points, code point ranges, implicit
  # union, <tt>&</tt> intersection, <tt>-</tt> difference, nested sets, a
  # leading <tt>^</tt> complement, multi-character string elements in braces,
  # ICU escapes, General_Category and binary Unicode properties, and the
  # pseudo-properties ANY, ASCII and ASSIGNED.
  #
  # A braced multi-character sequence is one element and is never split into
  # code points. A braced one-character sequence is normalized to that code
  # point.
  class UnicodeSet

    MAX_CODE_POINT = 0x10FFFF

    GENERAL_CATEGORY_RANGES =
      Impl.read_code_point_range_map("unicode_set_general_categories")
    GENERAL_CATEGORY_ALIASES =
      Impl.read_two_column_name_map("unicode_set_general_category_aliases")
    BINARY_PROPERTY_RANGES =
      Impl.read_code_point_range_map("unicode_set_properties")
    BINARY_PROPERTY_ALIASES =
      Impl.read_two_column_name_map("unicode_set_property_aliases")

    GENERAL_CATEGORY_GROUPS = {
      "C" => %w[Cc Cf Cn Co Cs],
      "L" => %w[Ll Lm Lo Lt Lu],
      "LC" => %w[Ll Lt Lu],
      "M" => %w[Mc Me Mn],
      "N" => %w[Nd Nl No],
      "P" => %w[Pc Pd Pe Pf Pi Po Ps],
      "S" => %w[Sc Sk Sm So],
      "Z" => %w[Zl Zp Zs]
    }.freeze

    PATTERN_WHITESPACE = [
      0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85,
      0x200E, 0x200F, 0x2028, 0x2029
    ].freeze

    Content = Struct.new(:ranges, :strings, :inverted)

    class ParseError < ArgumentError; end

    class << self

      def parse(pattern)
        new(pattern)
      end

      def empty_content
        Content.new([], [], false)
      end

      def all_content
        Content.new([[0, MAX_CODE_POINT]], [], false)
      end

      def code_point_content(code_point)
        Content.new([[code_point, code_point]], [], false)
      end

      def merge_ranges(ranges)
        sorted = ranges.reject { |first, last| first > last }.sort
        sorted.each_with_object([]) { |(first, last), merged|
          if merged.empty? || first > merged.last[1] + 1
            merged << [first, last]
          elsif last > merged.last[1]
            merged.last[1] = last
          end
        }
      end

      def union_content(left, right)
        prepared = prepare_binary(left, right)
        Content.new(
          merge_ranges(prepared[0].ranges + prepared[1].ranges),
          (prepared[0].strings + prepared[1].strings).uniq,
          false)
      end

      def intersection_content(left, right)
        prepared = prepare_binary(left, right)
        Content.new(
          intersection_ranges(prepared[0].ranges, prepared[1].ranges),
          prepared[1].strings.empty? ?
            prepared[0].strings : prepared[0].strings & prepared[1].strings,
          false)
      end

      def difference_content(left, right)
        prepared = prepare_binary(left, right)
        Content.new(
          difference_ranges(prepared[0].ranges, prepared[1].ranges),
          prepared[0].strings - prepared[1].strings,
          false)
      end

      def invert_content(content)
        Content.new(content.ranges.dup, content.strings.dup, !content.inverted)
      end

      def as_material_content(content)
        materialize(Content.new(content.ranges.dup, content.strings.dup, content.inverted))
      end

      def range_include?(ranges, code_point)
        first_index = 0
        last_index = ranges.length - 1
        while first_index <= last_index
          middle = (first_index + last_index) / 2
          first, last = ranges[middle]
          return true if code_point.between?(first, last)
          if code_point < first
            last_index = middle - 1
          else
            first_index = middle + 1
          end
        end
        false
      end

      def loose_name(name)
        name.downcase.gsub(/[\s_\-]/, "")
      end

      def property_content(name, value, inverted)
        content = PropertyResolver.new(name, value).content
        if inverted
          Content.new(content.ranges.dup, content.strings.dup, true)
        else
          content
        end
      end

      private

      def intersection_ranges(left, right)
        result = []
        left_index = 0
        right_index = 0
        while left_index < left.length && right_index < right.length
          first = [left[left_index][0], right[right_index][0]].max
          last = [left[left_index][1], right[right_index][1]].min
          result << [first, last] if first <= last
          if left[left_index][1] < right[right_index][1]
            left_index += 1
          else
            right_index += 1
          end
        end
        result
      end

      def difference_ranges(left, right)
        result = left.map { |first, last| [first, last] }
        right.each { |removed_first, removed_last|
          result = result.each_with_object([]) { |(first, last), remaining|
            next remaining << [first, last] if removed_last < first || removed_first > last
            remaining << [first, removed_first - 1] if removed_first > first
            remaining << [removed_last + 1, last] if removed_last < last
          }
        }
        merge_ranges(result)
      end

      def materialize(content)
        content.ranges = complement_ranges(content.ranges) if content.inverted
        content.inverted = false
        content
      end

      def complement_ranges(ranges)
        difference_ranges([[0, MAX_CODE_POINT]], ranges)
      end

      def prepare_binary(left, right)
        [as_material_content(left), as_material_content(right)]
      end

    end

    def initialize(pattern)
      unless pattern.respond_to?(:to_str)
        raise TypeError, "UnicodeSet pattern must respond to to_str"
      end
      @source = pattern.to_str
      @content = Parser.new(@source).parse
      canonicalize
    end

    def include?(item)
      if item.kind_of?(Integer)
        include_code_point?(item)
      elsif item.respond_to?(:to_str)
        string = item.to_str
        code_points = string.each_codepoint.to_a
        if code_points.length == 1
          include_code_point?(code_points.first)
        else
          @content.strings.include?(string)
        end
      elsif item.respond_to?(:ord)
        include_code_point?(item.ord)
      else
        false
      end
    end
    alias_method :member?, :include?
    alias_method :contains?, :include?

    def include_code_point?(code_point)
      return false unless code_point.between?(0, MAX_CODE_POINT)
      included = self.class.range_include?(@content.ranges, code_point)
      @content.inverted ? !included : included
    end

    def to_pattern
      body = pattern_body(@content)
      @content.inverted ? "[^#{body}]" : "[#{body}]"
    end
    alias_method :to_s, :to_pattern

    def inspect
      "#<#{self.class.name}: #{to_pattern}>"
    end

    def ==(other)
      other.kind_of?(UnicodeSet) && other.to_pattern == to_pattern
    end
    alias_method :eql?, :==

    def hash
      to_pattern.hash
    end

    private

    def canonicalize
      @content.ranges = self.class.merge_ranges(@content.ranges)
      strings = @content.strings.select { |string|
        string.each_codepoint.to_a.length != 1
      }
      @content.strings = strings.uniq.sort
    end

    def pattern_body(content)
      ranges = content.ranges.map { |first, last|
        if first == last
          first == 0x2D ? "\\-" : escape_code_point(first)
        else
          escape_endpoint(first) + "-" + escape_endpoint(last)
        end
      }
      strings = content.strings.map { |string|
        "{" + string.each_codepoint.map { |cp| escape_string_code_point(cp) }.join + "}"
      }
      (ranges + strings).join
    end

    def escape_endpoint(code_point)
      code_point == 0x2D ? "\\-" : escape_code_point(code_point)
    end

      def escape_code_point(code_point)
      special = [0x5B, 0x5D, 0x7B, 0x7D, 0x5C, 0x26, 0x5E, 0x2D]
      if special.include?(code_point) || code_point < 0x20 ||
          PATTERN_WHITESPACE.include?(code_point) ||
          (code_point >= 0x7F && code_point <= 0x9F)
        code_point == 0x20 ? "\\ " : format("\\u%04X", code_point)
      elsif code_point.between?(0xD800, 0xDFFF)
        format("\\u%04X", code_point)
      elsif code_point > 0xFFFF
        format("\\u{%X}", code_point)
      else
        code_point.chr(Encoding::UTF_8)
      end
    end

    def escape_string_code_point(code_point)
      case code_point
      when 0x5B, 0x5D, 0x7B, 0x7D, 0x5C, 0x26, 0x5E
        "\\" + code_point.chr(Encoding::UTF_8)
      when 0x2D
        "\\-"
      when 0x20
        "\\" + 0x20.chr(Encoding::UTF_8)
      else
        escape_code_point(code_point)
      end
    end

    class Parser

      SIMPLE_ESCAPES = {
        0x61 => 0x07,
        0x62 => 0x08,
        0x74 => 0x09,
        0x6E => 0x0A,
        0x76 => 0x0B,
        0x66 => 0x0C,
        0x72 => 0x0D
      }.freeze

      def initialize(text)
        text = text.to_str
        unless text.encoding == Encoding::UTF_8 || text.ascii_only?
          text = text.encode(Encoding::UTF_8)
        end
        @scanner = StringScanner.new(text)
      end

      def parse
        skip_pattern_whitespace
        expect("[")
        content = parse_bracket_content
        skip_pattern_whitespace
        unless @scanner.eos?
          raise_parse_error("unexpected text after UnicodeSet")
        end
        content
      end

      private

      def parse_bracket_content
        inverted = @scanner.scan(/\^/) ? true : false
        content = parse_sequence
        expect("]")
        content = UnicodeSet.invert_content(content) if inverted
        content
      end

      def parse_sequence
        accumulator = UnicodeSet.empty_content
        skip_pattern_whitespace
        return accumulator if @scanner.eos? || @scanner.check(/\]/)

        leading = true
        until @scanner.eos? || @scanner.check(/\]/)
          factor, simple = parse_factor(leading)
          leading = false
          factor = parse_factor_range(factor, simple)

          loop do
            skip_pattern_whitespace
            if @scanner.scan(/&/)
              right, right_simple = parse_factor(false)
              right = parse_factor_range(right, right_simple)
              factor = UnicodeSet.intersection_content(factor, right)
            elsif @scanner.scan(/-/)
              skip_pattern_whitespace
              if @scanner.eos? || @scanner.check(/\]/)
                factor = UnicodeSet.union_content(
                  factor, UnicodeSet.code_point_content(0x2D))
                break
              end
              right, right_simple = parse_factor(false)
              right = parse_factor_range(right, right_simple)
              factor = UnicodeSet.difference_content(factor, right)
            else
              break
            end
          end

          accumulator = UnicodeSet.union_content(accumulator, factor)
          skip_pattern_whitespace
        end
        accumulator
      end

      def parse_factor_range(factor, simple)
        return factor unless simple
        position = @scanner.pos
        skip_pattern_whitespace
        return factor unless @scanner.scan(/-/)
        skip_pattern_whitespace
        if @scanner.eos? || @scanner.check(/\]/)
          @scanner.pos = position
          return factor
        end
        endpoint, endpoint_simple = parse_factor(false)
        unless endpoint_simple
          @scanner.pos = position
          return factor
        end
        first = factor.ranges.first.first
        last = endpoint.ranges.first.first
        raise_parse_error("invalid code point range") if first > last
        Content.new([[first, last]], [], false)
      end

      def parse_factor(leading)
        skip_pattern_whitespace
        if @scanner.check(/\[/)
          if @scanner.rest.start_with?("[:") || @scanner.rest.start_with?("[^:")
            [parse_posix_property, false]
          else
            @scanner.getch
            [parse_bracket_content, false]
          end
        elsif @scanner.rest.start_with?("\\p", "\\P")
          [parse_backslash_property, false]
        elsif @scanner.check(/\{/)
          [parse_string, false]
        else
          code_point = parse_escaped_or_plain_code_point(leading)
          if code_point
            [UnicodeSet.code_point_content(code_point), true]
          else
            raise_parse_error("invalid set element")
          end
        end
      end

      def parse_escaped_or_plain_code_point(leading = false)
        if @scanner.scan(/\\/)
          parse_escape
        elsif leading && @scanner.check(/-/)
          @scanner.getch
          0x2D
        elsif leading && @scanner.check(/\^/)
          nil
        elsif !@scanner.check(/[\]\[&{\\-]/) && !@scanner.eos?
          parse_plain_code_point
        end
      end

      def parse_plain_code_point
        matched = @scanner.scan(/./u)
        raise_parse_error("invalid code point") unless matched
        code_point = matched.ord
        validate_code_point(code_point)
        code_point
      end

      def parse_escape
        code_point =
          if @scanner.scan(/u/i)
            parse_unicode_escape
          elsif @scanner.scan(/x/i)
            parse_hex_escape
          elsif @scanner.scan(/c/i)
            letter = @scanner.getch
            raise_parse_error("invalid control escape") unless letter
            letter.upcase.ord & 0x1F
          elsif (digits = @scanner.scan(/[0-7]{1,3}/))
            digits.to_i(8)
          elsif (matched = @scanner.scan(/./u))
            SIMPLE_ESCAPES[matched.ord] || matched.ord
          else
            raise_parse_error("dangling escape")
          end
        validate_code_point(code_point)
        code_point
      end

      def parse_unicode_escape
        if @scanner.scan(/\{/)
          digits = @scanner.scan(/[0-9A-Fa-f]+/)
          expect("}")
        else
          digits = @scanner.scan(/[0-9A-Fa-f]{4}/)
        end
        raise_parse_error("invalid unicode escape") unless digits
        digits.to_i(16)
      end

      def parse_hex_escape
        if @scanner.scan(/\{/)
          digits = @scanner.scan(/[0-9A-Fa-f]+/)
          expect("}")
        else
          digits = @scanner.scan(/[0-9A-Fa-f]{2}/)
        end
        raise_parse_error("invalid hex escape") unless digits
        digits.to_i(16)
      end

      def parse_string
        expect("{")
        code_points = []
        until @scanner.check(/}/) || @scanner.eos?
          if @scanner.scan(/\\/)
            code_points << parse_escape
          else
            code_points << parse_plain_code_point
          end
        end
        expect("}")
        raise_parse_error("empty string element") if code_points.empty?
        if code_points.length == 1
          UnicodeSet.code_point_content(code_points.first)
        else
          Content.new([], [pack_code_points(code_points)], false)
        end
      end

      def parse_posix_property
        expect("[")
        expect(":")
        inverted = @scanner.scan(/\^/) ? true : false
        body = @scanner.scan_until(/:/)
        raise_parse_error("unterminated property") unless body
        expect("]")
        UnicodeSet.property_content(*parse_property_body(body[0..-2]), inverted)
      end

      def parse_backslash_property
        backslash = @scanner.getch
        property_letter = @scanner.getch
        inverted = property_letter == "P" ? true : false
        if @scanner.scan(/\{/)
          body = @scanner.scan_until(/}/)
          raise_parse_error("unterminated property") unless body
          body = body[0..-2]
        else
          body = @scanner.scan(/[A-Za-z0-9&]+/)
        end
        raise_parse_error("invalid property") unless body && !body.empty?
        UnicodeSet.property_content(*parse_property_body(body), inverted)
      end

      def parse_property_body(body)
        name, separator, value = body.partition(/[=:]/)
        value = nil if separator.empty?
        [name.strip, value && value.strip]
      end

      def pack_code_points(code_points)
        code_points.map { |code_point|
          begin
            code_point.chr(Encoding::UTF_8)
          rescue RangeError
            [code_point].pack("U")
          end
        }.join.force_encoding(Encoding::UTF_8)
      end

      def validate_code_point(code_point)
        unless code_point.between?(0, MAX_CODE_POINT)
          raise_parse_error("code point outside Unicode range")
        end
      end

      def skip_pattern_whitespace
        while PATTERN_WHITESPACE.include?(peek_code_point)
          @scanner.getch
        end
      end

      def peek_code_point
        return nil if @scanner.eos?
        @scanner.rest.each_codepoint.first
      end

      def expect(token)
        unless @scanner.scan(Regexp.new(Regexp.escape(token)))
          raise_parse_error("expected #{token.inspect}")
        end
      end

      def raise_parse_error(message)
        raise ParseError, "#{message} at position #{@scanner.pos}"
      end

    end

    class PropertyResolver

      def initialize(name, value)
        @name = UnicodeSet.loose_name(name.to_s)
        @value = value.nil? ? nil : UnicodeSet.loose_name(value.to_s)
      end

      def content
        return pseudo_property if pseudo_property?
        if @value
          named_property
        else
          general_category(@name) || binary_property(@name, false) || unknown
        end
      end

      private

      def pseudo_property?
        %w[any ascii assigned].include?(@name)
      end

      def pseudo_property
        case @name
        when "any"
          UnicodeSet.all_content
        when "ascii"
          Content.new([[0, 0x7F]], [], false)
        when "assigned"
          UnicodeSet.difference_content(UnicodeSet.all_content, general_category("cn"))
        end
      end

      def named_property
        if %w[generalcategory gc].include?(@name)
          general_category(@value) || unknown
        elsif binary_value?
          inverted = %w[false no f n].include?(@value)
          binary_property(@name, inverted) || unknown
        else
          unknown
        end
      end

      def binary_value?
        %w[true false t f yes no y n].include?(@value)
      end

      def general_category(name)
        canonical = resolve(GENERAL_CATEGORY_ALIASES, name)
        return nil unless canonical
        members = GENERAL_CATEGORY_GROUPS[canonical] || [canonical]
        members.inject(UnicodeSet.empty_content) { |content, member|
          ranges = GENERAL_CATEGORY_RANGES[member]
          raise ParseError, "missing general category #{member}" unless ranges
          UnicodeSet.union_content(content, Content.new(ranges, [], false))
        }
      end

      def binary_property(name, inverted)
        canonical = resolve(BINARY_PROPERTY_ALIASES, name)
        return nil unless canonical
        ranges = BINARY_PROPERTY_RANGES[canonical]
        raise ParseError, "missing property #{canonical}" unless ranges
        content = Content.new(ranges, [], false)
        inverted ? UnicodeSet.invert_content(content) : content
      end

      def resolve(aliases, name)
        aliases.each_key { |key|
          return aliases[key] if UnicodeSet.loose_name(key) == name
        }
        nil
      end

      def unknown
        raise ParseError, "unsupported UnicodeSet property"
      end

    end

  end

end
