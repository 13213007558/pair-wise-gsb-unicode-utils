# -*- encoding: utf-8 -*-

require "test/unit"

require "unicode_utils/unicode_set"

class TestUnicodeSet < Test::Unit::TestCase

  UnicodeSet = UnicodeUtils::UnicodeSet

  def test_code_point_range_and_canonical_output
    set = UnicodeSet.parse("[a-z\\x{20AC}]")
    assert_equal "[a-z€]", set.to_s
    assert set.include?("a")
    assert set.include?(0x20AC)
    assert !set.include?("0")
  end

  def test_escaped_hyphen_is_not_a_range_operator
    set = UnicodeSet.parse("[a\\-z\\-]")
    assert_equal "[\\-az]", set.to_s
    assert set.include?("-")
    assert !set.include?("m")
  end

  def test_nested_intersection_and_difference
    set = UnicodeSet.parse("[[a-z] & [a-c] - [b]]")
    assert_equal "[ac]", set.to_s
    assert set.include?("a")
    assert !set.include?("b")
    assert set.include?("c")
    assert !set.include?("d")
  end

  def test_difference_operator_before_nested_and_property_terms
    assert_equal "[a]", UnicodeSet.parse("[a-[b]]").to_s
    assert_equal "[a]", UnicodeSet.parse("[a-\\p{Lu}]").to_s
    assert_equal "[a]", UnicodeSet.parse("[a-{b}]").to_s
  end

  def test_complement_and_strings_round_trip
    source = "[^a-z{a\\-b}]"
    pattern = "[^a-z{a-b}]"
    set = UnicodeSet.parse(source)
    assert_equal pattern, set.to_s
    assert_equal UnicodeSet.parse(set.to_s).to_s, set.to_s
    assert set.include?("A")
    assert !set.include?("a")
    assert set.include?("a-b")
    assert !set.include?("a")
  end

  def test_braced_string_is_one_element
    set = UnicodeSet.parse("[{ch}]")
    assert_equal "[{ch}]", set.to_s
    assert set.include?("ch")
    assert !set.include?("c")
    assert !set.include?("h")
  end

  def test_difference_removes_only_matching_string_elements
    set = UnicodeSet.parse("[[{ch}{xy}] - [{ch}]]")
    assert_equal "[{xy}]", set.to_s
    assert set.include?("xy")
    assert !set.include?("ch")
  end

  def test_property_aliases_are_fixed_to_unicode_6_2_0
    assert_equal "6.2.0", UnicodeSet::UNICODE_VERSION
    assert_equal UnicodeSet.parse("[\\p{Lu}]").to_a,
                 UnicodeSet.parse("[\\p{General_Category=Uppercase_Letter}]").to_a
    lc = UnicodeSet.parse("[\\p{LC}]")
    assert lc.include?("A")
    assert lc.include?("a")
    assert !lc.include?("0")
    assert UnicodeSet.parse("[\\p{Letter}]").include?("A")
    assert UnicodeSet.parse("[\\p{White_Space}]").include?(" ")
    assert UnicodeSet.parse("[\\P{Letter}]").include?("0")
  end

  def test_invalid_patterns_are_rejected
    assert_raise(ArgumentError) { UnicodeSet.parse("a-z") }
    assert_raise(ArgumentError) { UnicodeSet.parse("[z-a]") }
    assert_raise(ArgumentError) { UnicodeSet.parse("[\\p{No_Such_Property}]") }
  end

end
