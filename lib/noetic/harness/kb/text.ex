defmodule Noetic.Harness.KB.Text do
  @moduledoc """
  Words, for the knowledge base: how a title, a definition or a query becomes
  the terms `Noetic.Harness.KB.Index` counts.

  ## Two languages, one pipeline

  The extractions keep the corpus's language (`docs/kb/KB_SCHEMA.md`), and
  most of it is Russian, while an agent usually asks in English. So a term is
  not an ASCII word: text is split on anything that is not a Unicode letter or
  digit (`\\p{L}\\p{N}`), downcased, and `ё` is folded into `е`, which Russian
  writes both ways for the same word.

  ## Stemming, lightly, and why not Snowball

  Russian inflects: «память», «памяти», «памятью» are one word to a reader and
  three to `String.contains?/2`. Without folding them a Russian query finds
  only the records that happen to use its case. A full Snowball stemmer would
  be a dependency or a few hundred lines ported, and neither is justified until
  a light one is shown to fail, so this strips one inflectional ending:

    * Cyrillic words lose the longest noun or adjective ending that leaves a
      stem of at least three letters («героев», «героя» → «геро»;
      «памяти», «память» → «памят»). Verb endings (`-ет`, `-ит`, `-ть`) are
      deliberately absent: they are also the ends of nouns («бюджет», «совет»),
      and a query for a noun is the common case here.
    * Latin words lose a plural and `-ing`/`-ed`, then a final `e`/`y`
      («memories», «memory» → «memor»; «agents» → «agent»).

  Both are conflating — two different words can share a stem — and that is the
  usual price of a stemmer. The index and the query go through the same
  function, so whatever it does it does to both sides.
  """

  # The longest first, so «ами» is tried before «и».
  @ru_endings ~w(ыми ими ого его ому ему ами ями
                 ая яя ое ее ые ие ый ий ой ую юю ых их ым им
                 ах ях ам ям ов ев ей ом ем ию ия ии ье ья ьи ью
                 а я о е и ы у ю ь й)
              |> Enum.sort_by(&(-String.length(&1)))

  @ru_by_last Enum.group_by(@ru_endings, &binary_part(&1, byte_size(&1) - 2, 2))

  # Function words that occur in nearly every record and rank by frequency
  # rather than meaning. Short on purpose: a stopword list is a list of things
  # a query can no longer find.
  @stopwords MapSet.new(~w(
    the and for with from into that this are was were been has have not but its
    you your our can will may must should would what when where which who how
    of to in on at by or is be as an it a
    и в во не на с со что по для как это из к о об от а но или же ли бы
    при его ее их то так все был была были быть есть без до под над
  ))

  @doc """
  The terms of `text`: normalised, stop words dropped, each one stemmed.

      iex> Noetic.Harness.KB.Text.terms("Память героев и мира")
      ["памят", "геро", "мир"]

      iex> Noetic.Harness.KB.Text.terms("The agents' memories")
      ["agent", "memor"]
  """
  @spec terms(String.t() | nil) :: [String.t()]
  def terms(nil), do: []

  def terms(text) when is_binary(text) do
    text
    |> words()
    |> Enum.reject(&MapSet.member?(@stopwords, &1))
    |> Enum.map(&stem/1)
  end

  @doc "Normalised words, before stop words and stemming."
  @spec words(String.t()) :: [String.t()]
  def words(text) do
    normalised = normalise(text)
    normalised |> scan(0, nil, [], normalised) |> Enum.reverse()
  end

  # A word is a run of letters and digits. The scan is by hand, over bytes,
  # because it runs over every byte of the corpus when the index is built:
  # `:re.split/3` with `\p{L}` took 1.35 s of a 4.3 s build, and a `~r`
  # literal is compiled again on every call under this Elixir and OTP, which
  # was slower still. ASCII, Latin-1 and Cyrillic are decided by range, and
  # the rare letter outside them (Greek, accented Latin Extended) by
  # `other_letter?/1`.
  defp scan(<<c, rest::binary>>, pos, start, acc, whole)
       when c in ?a..?z or c in ?0..?9 or c in ?A..?Z,
       do: scan(rest, pos + 1, start || pos, acc, whole)

  defp scan(<<c, rest::binary>>, pos, start, acc, whole) when c < 0x80,
    do: scan(rest, pos + 1, nil, emit(acc, whole, start, pos), whole)

  defp scan(<<cp::utf8, rest::binary>>, pos, start, acc, whole) do
    size = byte_size(<<cp::utf8>>)

    if letter?(cp),
      do: scan(rest, pos + size, start || pos, acc, whole),
      else: scan(rest, pos + size, nil, emit(acc, whole, start, pos), whole)
  end

  # Not UTF-8: a separator, one byte at a time.
  defp scan(<<_, rest::binary>>, pos, start, acc, whole),
    do: scan(rest, pos + 1, nil, emit(acc, whole, start, pos), whole)

  defp scan(<<>>, pos, start, acc, whole), do: emit(acc, whole, start, pos)

  defp emit(acc, _whole, nil, _pos), do: acc

  defp emit(acc, whole, start, pos) do
    word = binary_part(whole, start, pos - start)

    # One character is not a word: «и», «в», a stray «x».
    if match?(<<_::utf8>>, word), do: acc, else: [word | acc]
  end

  defp letter?(cp) when cp in 0x0400..0x0481 or cp in 0x048A..0x052F, do: true
  defp letter?(cp) when cp in 0x00C0..0x024F, do: cp not in [0xD7, 0xF7]
  defp letter?(cp) when cp < 0x00C0, do: cp in [0xAA, 0xB5, 0xBA]
  # General punctuation, arrows, mathematical operators, box drawing: the
  # dashes, quotes and ellipses Russian prose is full of.
  defp letter?(cp) when cp in 0x2000..0x2BFF, do: false
  defp letter?(cp), do: other_letter?(cp)

  defp other_letter?(cp) do
    pattern =
      case :persistent_term.get({__MODULE__, :letter}, nil) do
        nil ->
          {:ok, pattern} = :re.compile("^[\\p{L}\\p{N}]$", [:unicode, :ucp])
          :persistent_term.put({__MODULE__, :letter}, pattern)
          pattern

        pattern ->
          pattern
      end

    :re.run(<<cp::utf8>>, pattern, [{:capture, :none}]) == :match
  end

  @doc """
  Downcased, with `ё` folded into `е`. Byte offsets survive it for Latin and
  Cyrillic text, which is what lets `snippet/3` find a match in the original.
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(text), do: text |> String.downcase() |> String.replace("ё", "е")

  @doc "One word's stem. See the moduledoc for what it strips and what it does not."
  @spec stem(String.t()) :: String.t()
  def stem(word) do
    case script(word) do
      :latin -> stem_latin(word)
      :cyrillic -> stem_cyrillic(word)
      :other -> word
    end
  end

  # By bytes rather than by regex: this runs once for every word of the
  # corpus when the index is built, and a regex per word was most of the
  # build's time.
  defp script(<<c, rest::binary>>) when c in ?a..?z, do: all_latin(rest)
  defp script(<<c, _, _::binary>> = word) when c in [0xD0, 0xD1], do: all_cyrillic(word)
  defp script(_), do: :other

  defp all_latin(<<>>), do: :latin
  defp all_latin(<<c, rest::binary>>) when c in ?a..?z, do: all_latin(rest)
  defp all_latin(_), do: :other

  # Lowercase Cyrillic is U+0430..U+044F (and U+0451, folded away by
  # `normalise/1`): two bytes each, D0 B0..D0 BF and D1 80..D1 8F.
  defp all_cyrillic(<<>>), do: :cyrillic
  defp all_cyrillic(<<0xD0, c, rest::binary>>) when c in 0xB0..0xBF, do: all_cyrillic(rest)
  defp all_cyrillic(<<0xD1, c, rest::binary>>) when c in 0x80..0x8F, do: all_cyrillic(rest)
  defp all_cyrillic(_), do: :other

  # Every letter is two bytes, so a stem of three letters is six. The endings
  # are looked up by the word's last letter, longest first, rather than all
  # fifty tried against every word.
  defp stem_cyrillic(word) when byte_size(word) >= 8 do
    last = binary_part(word, byte_size(word) - 2, 2)

    @ru_by_last
    |> Map.get(last, [])
    |> Enum.find_value(word, fn ending ->
      keep = byte_size(word) - byte_size(ending)

      if keep >= 6 and binary_part(word, keep, byte_size(ending)) == ending,
        do: binary_part(word, 0, keep)
    end)
  end

  defp stem_cyrillic(word), do: word

  defp stem_latin(word) do
    word
    |> plural()
    |> suffix()
    |> final()
  end

  defp plural(word) do
    cond do
      String.ends_with?(word, "ies") and byte_size(word) > 4 ->
        String.slice(word, 0..-4//1) <> "y"

      String.ends_with?(word, "sses") ->
        String.slice(word, 0..-3//1)

      String.ends_with?(word, ["ss", "us", "is"]) ->
        word

      String.ends_with?(word, "s") and byte_size(word) > 3 ->
        String.slice(word, 0..-2//1)

      true ->
        word
    end
  end

  defp suffix(word) do
    cond do
      String.ends_with?(word, "ing") and byte_size(word) >= 6 -> String.slice(word, 0..-4//1)
      String.ends_with?(word, "ed") and byte_size(word) >= 5 -> String.slice(word, 0..-3//1)
      true -> word
    end
  end

  defp final(word) do
    if String.ends_with?(word, ["e", "y"]) and byte_size(word) > 3,
      do: String.slice(word, 0..-2//1),
      else: word
  end

  @doc """
  About `width` characters of `text` around the first place one of `words`
  occurs, with an ellipsis where it was cut. `words` are normalised surface
  forms or stems; the match is a prefix match on the normalised text, so a stem
  finds its inflected forms. The start of the text when nothing matches.
  """
  @spec snippet(String.t(), [String.t()], pos_integer()) :: String.t()
  def snippet(text, words, width \\ 240) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()
    haystack = normalise(text)

    start =
      if byte_size(haystack) == byte_size(text) do
        words
        |> Enum.flat_map(fn word ->
          case :binary.match(haystack, word) do
            {at, _} -> [at]
            :nomatch -> []
          end
        end)
        |> Enum.min(fn -> 0 end)
      else
        0
      end

    # A byte offset into the normalised text, which the same offset in the
    # original matches because `normalise/1` kept the byte length. Turned into
    # a character index so the cut never splits a multi-byte letter.
    at = text |> binary_part(0, start) |> String.length()
    total = String.length(text)
    from = max(0, min(at - div(width, 3), total - width))
    cut = String.slice(text, from, width)

    (if(from > 0, do: "…", else: "") <> cut <> if(from + width < total, do: "…", else: ""))
    |> String.trim()
  end
end
