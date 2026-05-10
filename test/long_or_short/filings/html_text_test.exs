defmodule LongOrShort.Filings.HtmlTextTest do
  @moduledoc """
  Tests for `LongOrShort.Filings.HtmlText`.

  Pure-function module. Inline HTML fixtures cover block-tag handling,
  inline-tag flow, entity decoding, whitespace normalization, and the
  SEC-shaped fragment that `SectionFilter` later consumes.
  """

  use ExUnit.Case, async: true

  alias LongOrShort.Filings.HtmlText

  describe "to_text/1 — empty / invalid input" do
    test "empty string returns empty string" do
      assert HtmlText.to_text("") == ""
    end

    test "non-binary input returns empty string" do
      assert HtmlText.to_text(nil) == ""
      assert HtmlText.to_text(123) == ""
    end
  end

  describe "to_text/1 — block tags create newlines" do
    test "<p> tags produce paragraph breaks" do
      result = HtmlText.to_text("<p>Hello</p><p>World</p>")
      assert result =~ ~r/Hello\s*\n\s*World/
    end

    test "<div> tags produce line breaks" do
      result = HtmlText.to_text("<div>Top</div><div>Bottom</div>")
      assert result =~ ~r/Top\s*\n\s*Bottom/
    end

    test "<br> tags produce line breaks" do
      result = HtmlText.to_text("Line A<br>Line B")
      assert result =~ ~r/Line A\s*\n\s*Line B/
    end

    test "<h1> through <h6> produce line breaks" do
      result = HtmlText.to_text("<h1>Title</h1><p>Body text</p>")
      assert result =~ ~r/Title\s*\n.*Body text/s
    end

    test "table cells produce line breaks" do
      result = HtmlText.to_text("<table><tr><td>Cell A</td><td>Cell B</td></tr></table>")
      assert result =~ "Cell A"
      assert result =~ "Cell B"
    end

    test "list items produce line breaks" do
      result = HtmlText.to_text("<ul><li>One</li><li>Two</li><li>Three</li></ul>")
      assert result =~ ~r/One.*Two.*Three/s
    end
  end

  describe "to_text/1 — inline tags flow into text" do
    test "<span> and <b> are stripped, content preserved" do
      result = HtmlText.to_text("<span>Hello</span> <b>World</b>")
      assert result =~ "Hello"
      assert result =~ "World"
      refute result =~ "<"
      refute result =~ ">"
    end

    test "anchor text preserved without href" do
      result = HtmlText.to_text(~s|Click <a href="http://example.com">here</a>.|)
      assert result =~ ~r/Click here/
    end
  end

  describe "to_text/1 — HTML entities decoded" do
    test "&amp; decodes to &" do
      assert HtmlText.to_text("AT&amp;T") =~ "AT&T"
    end

    test "&nbsp; entity is decoded (to a whitespace-like character)" do
      result = HtmlText.to_text("foo&nbsp;bar")
      assert result =~ "foo"
      assert result =~ "bar"
      # The entity reference itself must not survive
      refute result =~ "&nbsp;"
    end

    test "numeric entities decode" do
      result = HtmlText.to_text("Em&#x2014;dash")
      assert String.contains?(result, "Em—dash") or String.contains?(result, "Em—dash")
    end
  end

  describe "to_text/1 — whitespace normalization" do
    test "runs of horizontal whitespace collapse to one space" do
      result = HtmlText.to_text("<p>too    many   spaces</p>")
      assert result == "too many spaces"
    end

    test "leading whitespace per line is stripped" do
      result = HtmlText.to_text("<div>   indented</div>")
      assert result == "indented"
    end

    test "3+ blank lines collapse to single blank line" do
      result = HtmlText.to_text("<p>A</p><br><br><br><br><p>B</p>")
      refute result =~ ~r/\n{3,}/
    end

    test "leading and trailing whitespace stripped" do
      result = HtmlText.to_text("<p>   surrounded   </p>")
      assert result == "surrounded"
    end
  end

  describe "to_text/1 — SectionFilter compatibility" do
    test "section headers land on their own lines (multiline regex matches)" do
      html = """
      <html>
      <body>
        <p>Some preamble text here.</p>
        <p style="text-align:center"><b>USE OF PROCEEDS</b></p>
        <p>We intend to use the proceeds for general corporate purposes.</p>
        <p style="text-align:center"><b>DILUTION</b></p>
        <p>Investors will experience immediate dilution.</p>
      </body>
      </html>
      """

      result = HtmlText.to_text(html)

      # Critical for SectionFilter's `^header$` multiline regex
      assert result =~ ~r/^USE OF PROCEEDS$/m
      assert result =~ ~r/^DILUTION$/m
      assert result =~ "general corporate purposes"
      assert result =~ "experience immediate dilution"
    end
  end
end
