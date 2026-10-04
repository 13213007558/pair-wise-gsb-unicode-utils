# -*- coding: utf-8 -*-

require "test/unit"
require "unicode_utils/scsu"

class TestSCSU < Test::Unit::TestCase

  STATIC_VECTOR = "\x03\x31\x03\x10\xE4\xE5\x12\xB0".b
  DYNAMIC_VECTOR = "\x1F\xFB\xC1\xC2".b
  UNICODE_VECTOR = "\x0F\x4E\x2D\x65\x87".b
  SUPPLEMENTARY_VECTOR = "\x0E\xD8\x01\x0E\xDC\x00".b

  def test_static_window_vector
    assert_equal "бАäåư", UnicodeUtils::SCSU.decode(STATIC_VECTOR)
  end

  def test_dynamic_window_vector
    assert_equal DYNAMIC_VECTOR, UnicodeUtils::SCSU.encode("αβ")
    assert_equal "αβ", UnicodeUtils::SCSU.decode(DYNAMIC_VECTOR)
  end

  def test_unicode_mode_vector
    assert_equal UNICODE_VECTOR, UnicodeUtils::SCSU.encode("中文")
    assert_equal "中文", UnicodeUtils::SCSU.decode(UNICODE_VECTOR)
  end

  def test_supplementary_plane_vector
    assert_equal SUPPLEMENTARY_VECTOR, UnicodeUtils::SCSU.encode("\u{10400}")
    assert_equal "\u{10400}", UnicodeUtils::SCSU.decode(SUPPLEMENTARY_VECTOR)
  end

  def test_feed_and_finish_at_every_split
    vectors = [
      STATIC_VECTOR,
      DYNAMIC_VECTOR,
      UNICODE_VECTOR,
      SUPPLEMENTARY_VECTOR,
      "\x0F\xD8\x3D\xDE\x00".b
    ]
    expected = ["бАäåư", "αβ", "中文", "\u{10400}", "\u{1F600}"]

    vectors.each_with_index do |vector, index|
      0.upto(vector.bytesize) do |split|
        decoder = UnicodeUtils::SCSU::Decoder.new
        result = decoder.feed(vector.byteslice(0, split))
        result << decoder.feed(vector.byteslice(split, vector.bytesize - split))
        result << decoder.finish
        assert_equal expected[index], result
      end
    end
  end

  def test_byte_by_byte_feed
    pairs = [
      [STATIC_VECTOR, "бАäåư"],
      [DYNAMIC_VECTOR, "αβ"],
      [UNICODE_VECTOR, "中文"],
      [SUPPLEMENTARY_VECTOR, "\u{10400}"],
      ["\x0F\xD8\x3D\xDE\x00".b, "\u{1F600}"]
    ]
    pairs.each do |vector, expected|
      decoder = UnicodeUtils::SCSU::Decoder.new
      result = String.new.force_encoding(Encoding::UTF_8)
      vector.each_byte do |byte|
        result << decoder.feed(byte.chr.b)
      end
      result << decoder.finish
      assert_equal expected, result
    end
  end

  def test_round_trip_dynamic_ranges_and_windows
    groups = [
      [0x20, 0x7F, 0x80, 0xFF, 0x131, 0x430, 0x3B1, 0x905],
      [0x3042, 0x30A2, 0x4E2D],
      [0xFF21],
      [0xE000, 0xFFFF, 0x10000, 0x1F600, 0x10FFFF]
    ]
    groups.each do |group|
      string = group.map { |point| point.chr(Encoding::UTF_8) }.join
      encoded = UnicodeUtils::SCSU.encode(string)
      assert_equal Encoding::BINARY, encoded.encoding
      assert_equal string, UnicodeUtils::SCSU.decode(encoded)
    end
  end

  def test_incomplete_and_invalid_streams
    assert_raise(UnicodeUtils::SCSU::InvalidEncoding) do
      decoder = UnicodeUtils::SCSU::Decoder.new
      decoder.feed("\x0E")
      decoder.finish
    end
    assert_raise(UnicodeUtils::SCSU::InvalidEncoding) do
      UnicodeUtils::SCSU.decode("\x18\xA8\x20")
    end
  end

end
