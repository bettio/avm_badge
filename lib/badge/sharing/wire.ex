defmodule Badge.Sharing.Wire do
  @moduledoc """
  What a share frame carries: one profile field, and which fields the
  sender is sharing.

      <<tag, mask, value::binary>>

  Tag 9 carries numbered fragments of a long name. Tags sit below 0x20,
  so a printable first byte is a bare name from older firmware.
  """

  import Bitwise

  alias Badge.Ir
  alias Badge.Profile

  # {key, tag}, in Profile.keys/0 order; the mask bit for a field is tag - 1.
  @tags [
    {:name, 1},
    {:company, 2},
    {:email, 3},
    {:github, 4},
    {:linkedin, 5},
    {:mastodon, 6},
    {:bluesky, 7},
    {:links, 8}
  ]

  @header 2
  @max_value Ir.max_payload() - @header
  @part_tag 9
  @part_value Ir.max_payload() - 4
  @max_parts div(Profile.capacity(:name) + @part_value - 1, @part_value)
  @legacy 0x20

  @doc "The fields a frame can carry, in tag order."
  @spec fields() :: [atom]
  def fields, do: for({key, _tag} <- @tags, do: key)

  @doc "The byte naming a field, or nil for a field no frame carries."
  @spec tag(atom) :: pos_integer | nil
  def tag(key), do: tag_of(@tags, key)

  @doc "The field a byte names, or nil."
  @spec key(integer) :: atom | nil
  def key(tag), do: key_of(@tags, tag)

  @doc "A payload carrying `value` under `key`, or an error the link would give."
  @spec encode(atom, [atom], binary) :: binary | {:error, :too_long | :unknown}
  def encode(_key, _shared, value) when byte_size(value) > @max_value, do: {:error, :too_long}

  def encode(key, shared, value) do
    case tag(key) do
      nil -> {:error, :unknown}
      tag -> <<tag, mask(shared)>> <> value
    end
  end

  @doc "Fragments of a name too long for one frame, as `{index, total, chunk}`."
  def name_parts(value) do
    total = div(byte_size(value) + @part_value - 1, @part_value)
    name_parts(value, 0, total, [])
  end

  defp name_parts(_value, total, total, acc), do: :lists.reverse(acc)

  defp name_parts(value, index, total, acc) do
    start = index * @part_value
    size = min(@part_value, byte_size(value) - start)
    chunk = :binary.part(value, start, size)
    name_parts(value, index + 1, total, [{index, total, chunk} | acc])
  end

  @doc "A numbered fragment of a long name."
  def encode_part(shared, index, total, chunk)
      when index >= 0 and index < total and total <= @max_parts and
             byte_size(chunk) > 0 and byte_size(chunk) <= @part_value do
    <<@part_tag, mask(shared), index, total>> <> chunk
  end

  def encode_part(_shared, _index, _total, _chunk), do: {:error, :too_long}

  @doc "Decodes a field, a numbered name fragment, or a bare legacy name."
  @spec decode(binary) ::
          {:ok, atom, [atom], binary}
          | {:part, [atom], non_neg_integer, pos_integer, binary}
          | :error
  def decode(<<first, _rest::binary>> = payload) when first >= @legacy do
    {:ok, :name, [:name], payload}
  end

  def decode(<<@part_tag, mask, index, total, chunk::binary>>)
      when total > 1 and total <= @max_parts and index < total and
             byte_size(chunk) > 0 and byte_size(chunk) <= @part_value do
    {:part, keys(mask), index, total, chunk}
  end

  def decode(<<tag, mask, value::binary>>) do
    case key(tag) do
      nil -> :error
      key -> {:ok, key, keys(mask), value}
    end
  end

  def decode(_payload), do: :error

  @doc "The mask with a bit set for each shared field; keys no frame carries are ignored."
  @spec mask([atom]) :: non_neg_integer
  def mask(shared), do: :lists.foldl(&set_bit/2, 0, shared)

  @doc "The fields a mask names, in tag order."
  @spec keys(non_neg_integer) :: [atom]
  def keys(mask), do: for({key, tag} <- @tags, band(mask, bsl(1, tag - 1)) != 0, do: key)

  defp set_bit(key, mask) do
    case tag(key) do
      nil -> mask
      tag -> bor(mask, bsl(1, tag - 1))
    end
  end

  defp tag_of([], _key), do: nil
  defp tag_of([{key, tag} | _rest], key), do: tag
  defp tag_of([_entry | rest], key), do: tag_of(rest, key)

  defp key_of([], _tag), do: nil
  defp key_of([{key, tag} | _rest], tag), do: key
  defp key_of([_entry | rest], tag), do: key_of(rest, tag)
end
