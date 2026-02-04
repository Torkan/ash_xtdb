# SPDX-FileCopyrightText: 2024 Torkild G. Kjevik
# SPDX-License-Identifier: MIT

defmodule AshXTDB.UTF8WorkaroundTest do
  use ExUnit.Case, async: true

  alias AshXTDB.UTF8Workaround

  describe "encode/1" do
    test "returns nil for nil input" do
      assert UTF8Workaround.encode(nil) == nil
    end

    test "returns empty string unchanged" do
      assert UTF8Workaround.encode("") == ""
    end

    test "returns ASCII string unchanged" do
      assert UTF8Workaround.encode("Hello World") == "Hello World"
    end

    test "returns BMP characters unchanged" do
      # Characters in Basic Multilingual Plane (U+0000 to U+FFFF)
      assert UTF8Workaround.encode("Héllo Wörld") == "Héllo Wörld"
      assert UTF8Workaround.encode("日本語") == "日本語"
      assert UTF8Workaround.encode("Привет") == "Привет"
    end

    test "encodes single emoji" do
      # 😀 is U+1F600
      assert UTF8Workaround.encode("😀") == "\\u{1F600}"
    end

    test "encodes emoji in text" do
      assert UTF8Workaround.encode("Hello 😀 World") == "Hello \\u{1F600} World"
    end

    test "encodes multiple emojis" do
      # 😀 is U+1F600, 🎉 is U+1F389
      assert UTF8Workaround.encode("😀🎉") == "\\u{1F600}\\u{1F389}"
    end

    test "encodes various 4-byte characters" do
      # 𝄞 (musical G clef) is U+1D11E
      assert UTF8Workaround.encode("𝄞") == "\\u{1D11E}"

      # 🏳️ (white flag) is U+1F3F3
      assert UTF8Workaround.encode("🏳") == "\\u{1F3F3}"
    end

    test "preserves mixed content" do
      input = "Test 123 日本語 😀 end"
      encoded = UTF8Workaround.encode(input)
      assert encoded == "Test 123 日本語 \\u{1F600} end"
    end
  end

  describe "decode/1" do
    test "returns nil for nil input" do
      assert UTF8Workaround.decode(nil) == nil
    end

    test "returns empty string unchanged" do
      assert UTF8Workaround.decode("") == ""
    end

    test "returns string without escapes unchanged" do
      assert UTF8Workaround.decode("Hello World") == "Hello World"
    end

    test "decodes single escape sequence" do
      assert UTF8Workaround.decode("\\u{1F600}") == "😀"
    end

    test "decodes escape in text" do
      assert UTF8Workaround.decode("Hello \\u{1F600} World") == "Hello 😀 World"
    end

    test "decodes multiple escapes" do
      assert UTF8Workaround.decode("\\u{1F600}\\u{1F389}") == "😀🎉"
    end

    test "decodes lowercase hex" do
      assert UTF8Workaround.decode("\\u{1f600}") == "😀"
    end

    test "decodes mixed case hex" do
      assert UTF8Workaround.decode("\\u{1F600}") == "😀"
      assert UTF8Workaround.decode("\\u{1f600}") == "😀"
      assert UTF8Workaround.decode("\\u{1F60a}") == "😊"
    end

    test "preserves non-escape content" do
      input = "Test 123 日本語 \\u{1F600} end"
      assert UTF8Workaround.decode(input) == "Test 123 日本語 😀 end"
    end
  end

  describe "encode/decode roundtrip" do
    test "roundtrip preserves original string with emojis" do
      original = "Hello 😀 World 🎉!"
      assert original |> UTF8Workaround.encode() |> UTF8Workaround.decode() == original
    end

    test "roundtrip preserves string without emojis" do
      original = "Hello World"
      assert original |> UTF8Workaround.encode() |> UTF8Workaround.decode() == original
    end

    test "roundtrip preserves mixed Unicode content" do
      original = "Héllo 日本語 😀 Wörld 🎉"
      assert original |> UTF8Workaround.encode() |> UTF8Workaround.decode() == original
    end

    test "roundtrip preserves nil" do
      assert nil |> UTF8Workaround.encode() |> UTF8Workaround.decode() == nil
    end

    test "roundtrip preserves empty string" do
      assert "" |> UTF8Workaround.encode() |> UTF8Workaround.decode() == ""
    end
  end

  describe "encode_deep/1" do
    test "returns nil for nil input" do
      assert UTF8Workaround.encode_deep(nil) == nil
    end

    test "encodes strings" do
      assert UTF8Workaround.encode_deep("Hello 😀") == "Hello \\u{1F600}"
    end

    test "encodes map values" do
      input = %{name: "Test 😀", age: 25}
      expected = %{name: "Test \\u{1F600}", age: 25}
      assert UTF8Workaround.encode_deep(input) == expected
    end

    test "encodes nested maps" do
      input = %{user: %{name: "Test 😀", emoji: "🎉"}}
      expected = %{user: %{name: "Test \\u{1F600}", emoji: "\\u{1F389}"}}
      assert UTF8Workaround.encode_deep(input) == expected
    end

    test "encodes lists" do
      input = ["a", "b 😀", "c"]
      expected = ["a", "b \\u{1F600}", "c"]
      assert UTF8Workaround.encode_deep(input) == expected
    end

    test "encodes maps with list values" do
      input = %{tags: ["a", "b 😀"]}
      expected = %{tags: ["a", "b \\u{1F600}"]}
      assert UTF8Workaround.encode_deep(input) == expected
    end

    test "passes through non-string values" do
      assert UTF8Workaround.encode_deep(123) == 123
      assert UTF8Workaround.encode_deep(true) == true
      assert UTF8Workaround.encode_deep(3.14) == 3.14
    end
  end

  describe "decode_deep/1" do
    test "returns nil for nil input" do
      assert UTF8Workaround.decode_deep(nil) == nil
    end

    test "decodes strings" do
      assert UTF8Workaround.decode_deep("Hello \\u{1F600}") == "Hello 😀"
    end

    test "decodes map values" do
      input = %{name: "Test \\u{1F600}", age: 25}
      expected = %{name: "Test 😀", age: 25}
      assert UTF8Workaround.decode_deep(input) == expected
    end

    test "decodes nested maps" do
      input = %{user: %{name: "Test \\u{1F600}", emoji: "\\u{1F389}"}}
      expected = %{user: %{name: "Test 😀", emoji: "🎉"}}
      assert UTF8Workaround.decode_deep(input) == expected
    end

    test "decodes lists" do
      input = ["a", "b \\u{1F600}", "c"]
      expected = ["a", "b 😀", "c"]
      assert UTF8Workaround.decode_deep(input) == expected
    end

    test "decodes maps with list values" do
      input = %{tags: ["a", "b \\u{1F600}"]}
      expected = %{tags: ["a", "b 😀"]}
      assert UTF8Workaround.decode_deep(input) == expected
    end

    test "passes through non-string values" do
      assert UTF8Workaround.decode_deep(123) == 123
      assert UTF8Workaround.decode_deep(true) == true
      assert UTF8Workaround.decode_deep(3.14) == 3.14
    end
  end

  describe "encode_deep/decode_deep roundtrip" do
    test "roundtrip preserves complex nested structure" do
      original = %{
        name: "Test 😀",
        tags: ["a", "b 🎉"],
        metadata: %{
          emoji: "🚀",
          nested: %{deep: "value 💯"}
        },
        count: 42
      }

      assert original |> UTF8Workaround.encode_deep() |> UTF8Workaround.decode_deep() == original
    end
  end

  describe "edge cases" do
    test "handles string that looks like escape but isn't" do
      # Make sure we don't double-encode
      input = "Test \\u{not-hex} value"
      encoded = UTF8Workaround.encode(input)
      # Should leave non-hex sequences alone
      assert encoded == input

      # Decode should also leave invalid sequences alone
      assert UTF8Workaround.decode(input) == input
    end

    test "handles already escaped string correctly" do
      # If someone has \\u{1F600} in their data (literal backslash)
      # This is tricky - but our regex should match it
      escaped_emoji = "\\u{1F600}"
      decoded = UTF8Workaround.decode(escaped_emoji)
      assert decoded == "😀"
    end

    test "handles empty maps and lists" do
      assert UTF8Workaround.encode_deep(%{}) == %{}
      assert UTF8Workaround.encode_deep([]) == []
      assert UTF8Workaround.decode_deep(%{}) == %{}
      assert UTF8Workaround.decode_deep([]) == []
    end

    test "passes through structs unchanged" do
      # DateTime and other structs should not be processed
      dt = ~U[2024-01-01 00:00:00Z]
      assert UTF8Workaround.encode_deep(dt) == dt
      assert UTF8Workaround.decode_deep(dt) == dt

      date = ~D[2024-01-01]
      assert UTF8Workaround.encode_deep(date) == date
      assert UTF8Workaround.decode_deep(date) == date
    end

    test "handles maps containing structs" do
      dt = ~U[2024-01-01 00:00:00Z]
      input = %{name: "Test 😀", timestamp: dt}
      encoded = UTF8Workaround.encode_deep(input)
      assert encoded == %{name: "Test \\u{1F600}", timestamp: dt}

      decoded = UTF8Workaround.decode_deep(%{name: "Test \\u{1F600}", timestamp: dt})
      assert decoded == %{name: "Test 😀", timestamp: dt}
    end
  end
end
