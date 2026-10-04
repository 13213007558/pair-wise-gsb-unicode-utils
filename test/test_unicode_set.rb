# encoding: utf-8

require "test/unit"
require "unicode_utils/unicode_set"

class TestUnicodeSet < Test::Unit::TestCase

  US = UnicodeUtils::UnicodeSet

  def test_unicode_version_is_fixed
    assert_equal "6.2.0", UnicodeUtils::UNICODE_VERSION
  end

  def test_code_points_ranges_and_set_operations
    set = US.new("[[a-d]-[c]&[b-z]]")
    assert_equal false, set.include?("a")
    assert_equal true, set.include?("b")
    assert_equal false, set.include?("c")
    assert_equal true, set.include?("d")
    assert_equal "[bd]", set.to_pattern
  end

  def test_nested_union_intersection_and_difference
    set = US.new("[[a-c]&[b-d]-b{ab}{cd}]")
    assert_equal "[c{ab}{cd}]", set.to_pattern
    assert_equal true, set.include?("c")
    assert_equal false, set.include?("b")
    assert_equal true, set.include?("ab")
    assert_equal true, set.include?("cd")
  end

  def test_complement
    set = US.new("[^a-z]")
    assert_equal false, set.include?("a")
    assert_equal true, set.include?("A")
    assert_equal "[^a-z]", set.to_pattern
  end

  def test_multi_character_string_is_one_element
    set = US.new("[{ab}]")
    assert_equal true, set.include?("ab")
    assert_equal false, set.include?("a")
    assert_equal false, set.include?("b")
    assert_equal "[{ab}]", set.to_pattern
  end

  def test_string_intersection_with_code_point_property
    set = US.new("[{ab}&[:Lu:]]")
    assert_equal true, set.include?("ab")
    assert_equal "[{ab}]", set.to_pattern
  end

  def test_escaped_hyphen_nested_difference_and_string_roundtrip
    pattern = "[a\\-z[[a-c]-[b]]-{ab}{cd}]"
    set = US.new(pattern)
    canonical = "[\\-acz{cd}]"
    assert_equal canonical, set.to_pattern
    assert_equal canonical, US.new(set.to_pattern).to_pattern
    assert_equal true, set.include?("-")
    assert_equal true, set.include?("cd")
    assert_equal false, set.include?("ab")
  end

  def test_escapes_and_ranges
    set = US.new("[\\u{41}-\\u0044\\n\\x45]")
    assert_equal "[\\u000AA-E]", set.to_pattern
    assert_equal true, set.include?(0x0A)
    assert_equal false, set.include?(0x0D)
  end

  def test_general_category_aliases
    set = US.new("[\\p{gc=L&}]")
    assert_equal true, set.include?("A")
    assert_equal true, set.include?("a")
    assert_equal true, US.new("[[:Uppercase_Letter:]]").include?("A")
    assert_equal false, US.new("[[:Uppercase_Letter:]]").include?("a")
  end

  def test_binary_properties_and_complements
    set = US.new("[[:White_Space:]]")
    assert_equal true, set.include?(" ")
    assert_equal false, set.include?("A")
    complement = US.new("[\\P{ASCII}]")
    assert_equal false, complement.include?("A")
    assert_equal true, complement.include?("é")
    assert_equal true, US.new("[\\p{White_Space=Yes}]").include?(" ")
    assert_equal false, US.new("[\\p{White_Space=No}]").include?(" ")
  end

  def test_pseudo_properties
    assert_equal true, US.new("[\\p{ANY}]").include?(0x10FFFF)
    assert_equal true, US.new("[\\p{ASCII}]").include?(0x7F)
    assert_equal false, US.new("[\\p{ASCII}]").include?(0x80)
    assert_equal true, US.new("[\\p{ASSIGNED}]").include?("A")
    assert_equal false, US.new("[\\p{ASSIGNED}]").include?(0x378)
  end

  def test_invalid_patterns
    assert_raise(UnicodeUtils::UnicodeSet::ParseError) { US.new("[z-a]") }
    assert_raise(UnicodeUtils::UnicodeSet::ParseError) { US.new("[{}]") }
    assert_raise(UnicodeUtils::UnicodeSet::ParseError) { US.new("[a") }
    assert_raise(UnicodeUtils::UnicodeSet::ParseError) { US.new("[\\p{Unknown_Property}]") }
  end

end
