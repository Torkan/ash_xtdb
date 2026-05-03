# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.Connection.ArrayDecoderTest do
  use ExUnit.Case, async: true

  alias AshXTDB.Connection.ArrayDecoder

  describe "parse/1" do
    test "empty array" do
      assert ArrayDecoder.parse("{}") == []
    end

    test "unquoted numeric elements" do
      assert ArrayDecoder.parse("{1,2,3}") == ["1", "2", "3"]
    end

    test "quoted string elements" do
      assert ArrayDecoder.parse(~s({"a","b"})) == ["a", "b"]
    end

    test "single empty string element" do
      assert ArrayDecoder.parse(~s({""})) == [""]
    end

    test "NULL element" do
      assert ArrayDecoder.parse("{NULL,1,NULL}") == [nil, "1", nil]
    end

    test "quoted element containing a comma" do
      assert ArrayDecoder.parse(~s({"a,b","c"})) == ["a,b", "c"]
    end

    test "quoted element containing escaped quote" do
      assert ArrayDecoder.parse(~s({"x\\"y"})) == [~s(x"y)]
    end

    test "quoted element containing escaped backslash" do
      assert ArrayDecoder.parse(~s({"a\\\\b"})) == [~s(a\\b)]
    end

    test "ISO date strings (unquoted)" do
      assert ArrayDecoder.parse("{2024-01-01,2024-02-02}") == ["2024-01-01", "2024-02-02"]
    end

    test "raises on missing opening brace" do
      assert_raise ArgumentError, fn -> ArrayDecoder.parse("1,2,3") end
    end

    test "raises on unterminated input" do
      assert_raise ArgumentError, fn -> ArrayDecoder.parse("{1,2") end
    end
  end
end
