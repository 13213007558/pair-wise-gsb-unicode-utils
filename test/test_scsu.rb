# -*- encoding: utf-8 -*-

require "test/unit"
require "unicode_utils/scsu"

class TestSCSU < Test::Unit::TestCase

  def assert_encoded(expected_hex, text)
    bytes = expected_hex.scan(/../).map { |byte| byte.to_i(16) }.pack("C*")
    assert_equal bytes, UnicodeUtils::SCSU.encode(text)
    assert_equal text, UnicodeUtils::SCSU.decode(bytes)
  end

  def test_static_literal
    assert_encoded "e1", "a"
  end

  def test_quoted_static_window
    assert_encoded "0400", "\u0300"
  end

  def test_static_window_offsets
    assert_equal "\u301f", UnicodeUtils::SCSU.decode([0x08, 0x1F].pack("C*"))
  end

  def test_dynamic_window
    assert_encoded "064c", "\u20ac"
  end

  def test_defined_dynamic_window
    assert_encoded "11065b", "\u03bb"
  end

  def test_unicode_mode_bmp
    assert_encoded "0f4f60", "\u4f60"
  end

  def test_unicode_mode_command_byte_range
    assert_encoded "0f8a00", "\u8a00"
    assert_encoded "0f0e9a00", "\u9a00"
  end

  def test_unicode_mode_supplementary_plane
    text = "\u{1f600}"
    bytes = [0x0F, 0x0E, 0xD8, 0x3D, 0xDE, 0x00].pack("C*")
    assert_equal bytes, UnicodeUtils::SCSU.encode(text)
    assert_equal text, UnicodeUtils::SCSU.decode(bytes)
  end

  def test_supplementary_plane_dynamic_window
    text = "\u{10420}"
    assert_encoded "11d240", text
  end

  def test_quoted_dynamic_window
    bytes = [0x02, 0xA0].pack("C*")
    assert_equal "\u00a0", UnicodeUtils::SCSU.decode(bytes)
  end

  def test_feed_finish_decoder
    bytes = UnicodeUtils::SCSU.encode("a\u{10420}\u{1f600}z")
    decoder = UnicodeUtils::SCSU::Decoder.new
    result = decoder.feed(bytes.byteslice(0, 3)) +
             decoder.feed(bytes.byteslice(3, 2)) +
             decoder.feed(bytes.byteslice(5, 2)) +
             decoder.feed(bytes.byteslice(7..-1)) +
             decoder.finish
    assert_equal "a\u{10420}\u{1f600}z", result
  end

  def test_feed_finish_encoder
    text = "\u{10420}z"
    encoder = UnicodeUtils::SCSU::Encoder.new
    result = encoder.feed(text.byteslice(0, 1)) +
             encoder.feed(text.byteslice(1, 2)) +
             encoder.feed(text.byteslice(3..-1)) +
             encoder.finish
    assert_equal UnicodeUtils::SCSU.encode(text), result
    assert_equal text, UnicodeUtils::SCSU.decode(result)
  end

  def test_decode_at_every_byte_boundary
    texts = [
      "a\u0300\u20ac\u03bb\u4f60\u{10420}\u{1f600}z",
      "\u{1f600}\u{10420}\u4f60\u03bb\u20ac\u0300a"
    ]

    texts.each do |text|
      bytes = UnicodeUtils::SCSU.encode(text)
      (0..bytes.bytesize).each do |position|
        decoder = UnicodeUtils::SCSU::Decoder.new
        result = decoder.feed(bytes.byteslice(0, position)) +
                 decoder.feed(bytes.byteslice(position..-1)) +
                 decoder.finish
        assert_equal text, result
      end
    end
  end

  def test_decode_at_every_chunk_point
    text = "a\u0300\u20ac\u03bb\u4f60\u{10420}\u{1f600}z"
    bytes = UnicodeUtils::SCSU.encode(text)
    bytes.each_byte.with_index do |_, position|
      decoder = UnicodeUtils::SCSU::Decoder.new
      chunks = [bytes.byteslice(0, position), bytes.byteslice(position..-1)]
      result = chunks.map { |chunk| decoder.feed(chunk) }.join + decoder.finish
      assert_equal text, result
    end
  end

  def test_round_trip_selection
    text = "SCSU mixes ASCII, \u03bb\u03ad\u03be\u03b7, " +
           "\u4f60\u597d\u4e16\u754c, " +
           "\u{10420}\u{10421}\u{10422}\u{10423}\u{10424}\u{10425}."
    bytes = UnicodeUtils::SCSU.encode(text)
    assert_equal text, UnicodeUtils::SCSU.decode(bytes)
    assert bytes.bytesize < text.bytesize
  end

  def test_many_scalar_values
    points = (0x0000..0x1FFF).reject do |point|
      point >= 0xD800 && point <= 0xDFFF
    end
    points += [0x33FF, 0x3400, 0x4E00, 0xFFFD, 0x10000, 0x103FF,
              0x10420, 0x116FF, 0x1F600, 0x1033FF]
    text = points.uniq.pack("U*")
    bytes = UnicodeUtils::SCSU.encode(text)
    assert_equal text, UnicodeUtils::SCSU.decode(bytes)

    (0..bytes.bytesize).step(37).each do |position|
      decoder = UnicodeUtils::SCSU::Decoder.new
      result = decoder.feed(bytes.byteslice(0, position)) +
               decoder.feed(bytes.byteslice(position..-1)) +
               decoder.finish
      assert_equal text, result
    end
  end

  def test_extended_dynamic_window
    text = "\u{100020}"
    extended_bytes = [
      0x0B,
      0x20,
      0x00,
      0xA0
    ].pack("C*")
    assert_equal text, UnicodeUtils::SCSU.decode(extended_bytes)
  end

  def test_unicode_quote
    single_quoted_bytes = [0x0E, 0x03, 0xBB].pack("C*")
    assert_equal "\u03bb", UnicodeUtils::SCSU.decode(single_quoted_bytes)

    unicode_quoted_bytes = [0x0F, 0x0E, 0x03, 0xBB, 0x00, 0x41].pack("C*")
    assert_equal "\u03bbA", UnicodeUtils::SCSU.decode(unicode_quoted_bytes)
  end

  def test_highest_dynamic_selector
    text = "\u{1033a0}"
    assert_equal text, UnicodeUtils::SCSU.decode([0x10, 0xFF, 0xA0].pack("C*"))
  end

  def test_reserved_single_command
    assert_raise UnicodeUtils::SCSU::DecodingError do
      UnicodeUtils::SCSU.decode([0x18].pack("C*"))
    end
  end

  def test_reserved_unicode_command
    assert_raise UnicodeUtils::SCSU::DecodingError do
      UnicodeUtils::SCSU.decode([0x0F, 0x9A].pack("C*"))
    end
  end

  def test_exit_unicode_mode
    assert_equal "", UnicodeUtils::SCSU.decode([0x0F, 0x9F].pack("C*"))
    assert_equal "a", UnicodeUtils::SCSU.decode([0x0F, 0x9F, 0xE1].pack("C*"))
    decoder = UnicodeUtils::SCSU::Decoder.new
    result = decoder.feed([0x0F, 0x9F].pack("C*")) +
             decoder.feed([0xE1].pack("C*")) + decoder.finish
    assert_equal "a", result
  end

  def test_unpaired_surrogate
    assert_raise UnicodeUtils::SCSU::DecodingError do
      UnicodeUtils::SCSU.decode([0x0F, 0xD8, 0x00, 0x0F].pack("C*"))
    end
  end

  def test_incomplete_stream
    assert_raise UnicodeUtils::SCSU::DecodingError do
      decoder = UnicodeUtils::SCSU::Decoder.new
      decoder.feed([0x0F, 0xD8, 0x3D].pack("C*"))
      decoder.finish
    end
  end

end
