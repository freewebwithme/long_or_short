defmodule LongOrShort.Filings.HtmlText do
  @moduledoc """
  HTML → plain text conversion for SEC filing bodies (LON-119).

  Used by `LongOrShort.Filings.BodyFetcher` to turn the multi-megabyte
  HTML documents SEC EDGAR serves into the plain-text form expected by
  `LongOrShort.Filings.SectionFilter` (whose `^header$` multiline regex
  requires section headings to live on their own lines).

  ## Approach

  Floki parses the document into a tree. We walk the tree and inject
  literal `"\\n"` text nodes around the children of any block-level
  element (`<p>`, `<div>`, `<br>`, `<h1>`–`<h6>`, `<tr>`, `<td>`,
  `<th>`, `<li>`, `<ul>`, `<ol>`, `<table>`, `<thead>`, `<tbody>`,
  `<section>`, `<article>`). `Floki.text/1` then concatenates every
  text node — including our injected newlines — yielding text whose
  block boundaries align with the visual layout of the rendered page.

  Inline elements (`<span>`, `<b>`, `<a>`, etc.) are left alone; their
  children flow into the surrounding text without inserted breaks.

  HTML entities (`&amp;`, `&#x2014;`, `&nbsp;`) are decoded by Floki
  during parsing — no manual decode pass needed.

  ## Whitespace normalization

  Post-extraction:

    * Runs of horizontal whitespace (spaces/tabs) collapse to a single
      space.
    * Leading whitespace on each line is stripped.
    * Three or more consecutive blank lines collapse to a single
      blank line (one `\\n\\n`).
    * Leading and trailing whitespace on the whole document is
      stripped.

  ## Defensive parsing

  Malformed HTML is the norm in SEC EDGAR filings (mixed namespaces,
  unclosed tags, XBRL inlining). `Floki.parse_fragment/1` is tolerant;
  on the rare hard failure we return `""` rather than crashing.
  """

  @block_tags ~w(p div br h1 h2 h3 h4 h5 h6 tr td th li ul ol table thead tbody section article)

  @doc """
  Convert an HTML string to plain text with block-level newlines preserved.

  Returns `""` on parse failure or empty input.
  """
  @spec to_text(binary()) :: binary()
  def to_text(html) when is_binary(html) and html != "" do
    case Floki.parse_fragment(html) do
      {:ok, tree} ->
        tree
        |> insert_block_breaks()
        |> Floki.text()
        |> normalize_whitespace()

      {:error, _} ->
        ""
    end
  end

  def to_text(_), do: ""

  defp insert_block_breaks(tree) do
    Floki.traverse_and_update(tree, fn
      {tag, attrs, children} when tag in @block_tags ->
        {tag, attrs, ["\n" | children] ++ ["\n"]}

      other ->
        other
    end)
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+/u, " ")
    |> String.replace(~r/\n[ \t]+/u, "\n")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end
end
