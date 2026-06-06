defmodule ExML.CFScript.Collections do
  @moduledoc """
  The boundary between the interpreter's reference-typed values
  (`ArrayRef`/`StructRef`) and the pure BIF families.

  Responsibilities (the "imperative shell" around the functional BIF core):

    * **Deref** ref arguments to raw lists/maps so the BIF families stay pure.
    * **Wrap** any raw list/map *result* into a fresh reference, so values
      flowing back into the program are mutable (matching Lucee, where
      `arrayMap`, `structKeyArray`, etc. yield new arrays/structs).
    * **Mutate** in place for the mutating BIFs (`arrayAppend`, `structInsert`,
      ...): compute the new collection with the pure family and write it back
      into the receiver's reference. The bare BIF returns `true`, as Lucee does.
    * **Member chaining**: for member calls, functions flagged
      `<member-chaining>` in Lucee's FLD return the receiver (e.g.
      `arr.append(x)` → `arr`, `arr.each(fn)` → `arr`); others return the BIF
      value (`arr.map(fn)` → new array).

  Member names and chaining flags are taken verbatim from Lucee 6.2.5's
  `core-base.fld`.
  """

  alias ExML.CFScript.{BIF.Registry, CFException, Heap, HigherOrder, Query, Value}
  alias ExML.CFScript.Value.{ArrayRef, QueryRef, StructRef}

  @type invoke :: (any(), [any()] -> any())

  # Mutating BIFs: mutate the first argument's collection in place. Most
  # bare-return true; the query mutators return a count (see mutator_return/2).
  @mutators ~w(
    arrayappend arrayprepend arraydeleteat arrayinsertat arrayset arrayclear
    structinsert structdelete structupdate structappend structclear
    queryaddrow querysetcell queryaddcolumn
  )

  # member-chaining=true functions (Lucee core-base.fld): the member form
  # returns the receiver instead of the BIF's value.
  @chaining MapSet.new(~w(
    arrayappend arrayprepend arrayclear arraydelete arraydeleteat arraydeletenocase
    arrayeach arrayinsertat arrayresize arrayset arraysort arrayswap
    structappend structclear structdelete structeach structinsert structupdate
  ))

  # member-name -> BIF name, only where it differs from "<type>" <> member.
  @array_member_overrides %{"size" => "arraylen"}
  @struct_member_overrides %{"len" => "structcount", "size" => "structcount"}

  # Ref-aware functions handled here rather than in a pure family.
  @ref_fns ~w(duplicate)

  @doc "Whether the interpreter should route `name` through this boundary."
  @spec handles?(String.t()) :: boolean()
  def handles?(name) do
    down = String.downcase(name)
    down in @ref_fns or HigherOrder.higher_order?(down) or Registry.builtin?(down)
  end

  @doc """
  Dispatch a bare built-in / higher-order call by name. Args may contain
  references; the result of a collection-producing call is a fresh reference.
  """
  @spec call(String.t(), [any()], invoke()) :: any()
  def call(name, args, invoke) do
    down = String.downcase(name)

    cond do
      down == "duplicate" -> deep_copy(hd(args))
      down in @mutators -> mutate(down, args)
      HigherOrder.higher_order?(down) -> wrap(HigherOrder.call(down, deref_all(args), invoke))
      true -> wrap(Registry.call(down, deref_all(args)))
    end
  end

  # duplicate/1: a deep copy — every nested array/struct becomes a new reference,
  # so the copy shares nothing mutable with the original.
  @spec deep_copy(any()) :: any()
  defp deep_copy(%ArrayRef{} = ref),
    do: ref |> Heap.deref() |> Enum.map(&deep_copy/1) |> Heap.new_array()

  defp deep_copy(%StructRef{} = ref) do
    ref |> Heap.deref() |> Map.new(fn {k, v} -> {k, deep_copy(v)} end) |> Heap.new_struct()
  end

  defp deep_copy(%QueryRef{} = ref) do
    %Query{columns: columns, rows: rows} = Heap.deref(ref)
    copied = Enum.map(rows, fn row -> Map.new(row, fn {k, v} -> {k, deep_copy(v)} end) end)
    Heap.new_query(%Query{columns: columns, rows: copied})
  end

  defp deep_copy(value), do: value

  @doc """
  Dispatch a member call `receiver.member(args)`, mapping the member name to its
  BIF by the receiver's type and applying member-chaining return semantics.
  """
  @spec member_call(any(), String.t(), [any()], invoke()) :: any()
  def member_call(receiver, member_name, args, invoke) do
    bif = member_bif(receiver, member_name)
    result = call(bif, [receiver | args], invoke)

    if Heap.ref?(receiver) and MapSet.member?(@chaining, bif), do: receiver, else: result
  end

  ## Mutation

  @spec mutate(String.t(), [any()]) :: any()
  defp mutate(name, [ref | _] = args) do
    new_collection = Registry.call(name, deref_all(args))

    if Heap.ref?(ref) do
      Heap.write(ref, new_collection)
    else
      raise CFException, message: "#{name}() expected an array/struct/query reference"
    end

    mutator_return(name, new_collection)
  end

  # Lucee mutator return values: arrays/structs return true; queryAddRow returns
  # the new record count, queryAddColumn the new column count.
  @spec mutator_return(String.t(), any()) :: any()
  defp mutator_return("queryaddrow", %Query{} = q), do: Query.record_count(q)
  defp mutator_return("queryaddcolumn", %Query{} = q), do: Query.column_count(q)
  defp mutator_return(_name, _new), do: true

  ## Deref / wrap

  @spec deref_all([any()]) :: [any()]
  defp deref_all(args), do: Enum.map(args, &Heap.deref/1)

  # Raw list/map/query results become fresh references; scalars pass through.
  @spec wrap(any()) :: any()
  defp wrap(%Query{} = query), do: Heap.new_query(query)
  defp wrap(value) when is_list(value), do: Heap.new_array(value)
  defp wrap(value) when is_map(value) and not is_struct(value), do: Heap.new_struct(value)
  defp wrap(value), do: value

  ## Member-name -> BIF-name mapping by receiver type

  @spec member_bif(any(), String.t()) :: String.t()
  defp member_bif(receiver, member_name) do
    down = String.downcase(member_name)

    cond do
      is_binary(receiver) ->
        down

      array_like?(receiver) ->
        Map.get(@array_member_overrides, down, "array" <> down)

      struct_like?(receiver) ->
        Map.get(@struct_member_overrides, down, "struct" <> down)

      true ->
        raise CFException,
          message: "Cannot call member '#{member_name}' on #{Value.display(receiver)}"
    end
  end

  @spec array_like?(any()) :: boolean()
  defp array_like?(%ArrayRef{}), do: true
  defp array_like?(value), do: is_list(value)

  @spec struct_like?(any()) :: boolean()
  defp struct_like?(%StructRef{}), do: true
  defp struct_like?(value), do: is_map(value) and not is_struct(value)
end
