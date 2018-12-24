defmodule ExML.Transpiler do
  @moduledoc """
  Transpiles EXmL source into EEx source.

  Ideally, transpiling would be skipped and EXmL source would compile
  directly to an AST.

  TODO: move these functions into a behaviour and have modules like ExML.Elements.CfloopRange.transpile()?
  or protocols, Transpiler.transpile, for: %CfloopRange{}, which would be extendable by the end-user

  TODO: accumulate into dynamic and static and zip together (optimization for compilation, if compiled)
  """

  @type token :: tuple()

  @doc """
  Transpile EXmL source into EEx source.
  """
  @spec transpile(binary()) ::
          {:ok, binary()}
          | {:ok, [any()], binary(), map(), {pos_integer(), pos_integer()}, pos_integer()}
  def transpile(source) do
    with {:ok, tokens, "", %{}, _column, _line} <- ExML.Tokenizer.parse(source) do
      do_transpile(tokens, [])
    end
  end

  # defp do_transpile(tokens, buffer \\ [])

  @spec do_transpile([token], [String.t()]) :: {:ok, String.t()}
  defp do_transpile([{:static, text} | tokens], buffer) do
    do_transpile(tokens, [text | buffer])
  end

  defp do_transpile([{:interpolation, {scope, variable}} | tokens], buffer) do
    do_transpile(tokens, ["<%= " <> scope <> "." <> variable <> " %>" | buffer])
  end

  # TODO: add clause for assigns {"assigns", variable} to prefix with @
  defp do_transpile([{:interpolation, {variable}} | tokens], buffer) do
    do_transpile(tokens, ["<%= " <> variable <> " %>" | buffer])
  end

  defp do_transpile([{:cfloop_query, opts} | tokens], buffer) do
    # TODO: require item attribute (to enforce a different variable is used inside the loop)
    # TODO: support max_rows attribute, mutually exclusive with end_row
    # TODO: support group attribute
    {attributes, inner_tokens} = Keyword.split(opts, [:query, :start_row, :end_row])
    query = Keyword.fetch!(attributes, :query)
    # TODO: support range
    # start_row = Keyword.get(attributes, :start_row)
    # end_row = Keyword.get(attributes, :end_row)
    {:ok, innards} = do_transpile(inner_tokens, buffer)

    do_transpile(tokens, [
      "<%= for #{query} <- @#{query} do %>#{innards}<% end %>"
      | buffer
    ])
  end

  defp do_transpile([{:cfloop_list, opts} | tokens], buffer) do
    {attributes, inner_tokens} = Keyword.split(opts, [:item, :list])

    # TODO: support literal lists (comma delimited? or use custom delimiter attribute?)
    [list: {:interpolation, {items}}, item: item] = attributes
    # TODO: pass `"item"` in a list of local vars here, so the transpilers knows to not add @
    # or explicitly label `assigns` variables up the chain somewhere.
    {:ok, innards} = do_transpile(inner_tokens, buffer)

    do_transpile(tokens, [
      "<%= for #{item} <- @#{items} do %>#{innards}<% end %>"
      | buffer
    ])
  end

  defp do_transpile([{:cfloop_range, opts} | tokens], buffer) do
    {attributes, inner_tokens} = Keyword.split(opts, [:from, :to, :index])

    # TODO: support variables here, not just literals
    [from: from, to: to, index: index] = attributes
    {:ok, innards} = do_transpile(inner_tokens, buffer)

    do_transpile(tokens, [
      "<%= for #{index} <- #{from}..#{to} do %>#{innards}<% end %>"
      | buffer
    ])
  end

  defp do_transpile([{:comment, text} | tokens], buffer) do
    do_transpile(tokens, ["<%#" <> text <> "%>" | buffer])
  end

  defp do_transpile([], buffer) do
    {:ok, join_buffer(buffer)}
  end

  @spec join_buffer([String.t()]) :: String.t()
  defp join_buffer(buffer) when is_list(buffer) do
    buffer |> Enum.reverse() |> Enum.join()
  end
end
