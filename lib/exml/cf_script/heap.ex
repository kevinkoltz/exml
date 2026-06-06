defmodule ExML.CFScript.Heap do
  @moduledoc """
  Mutable cells for CFML reference types (arrays and structs).

  In Lucee, arrays and structs are reference types: `b = a` aliases the same
  array, passing one to a function shares it, and `arr.append(x)` /
  `struct.key = v` mutate in place so the change is visible through every
  reference. Simple values (string/number/boolean) are value types.

  We model that with `ArrayRef`/`StructRef` structs (defined in
  `ExML.CFScript.Value`) holding an opaque cell, backed by the process
  dictionary — the interpreter runs synchronously in one process, so there is
  no cross-process sharing to worry about.
  """

  alias ExML.CFScript.Value.{ArrayRef, StructRef}

  @doc "Wrap a list as a fresh mutable array reference."
  @spec new_array([any()]) :: ArrayRef.t()
  def new_array(list) when is_list(list), do: %ArrayRef{cell: new_cell(list)}

  @doc "Wrap a map as a fresh mutable struct reference (keys already downcased)."
  @spec new_struct(map()) :: StructRef.t()
  def new_struct(map) when is_map(map), do: %StructRef{cell: new_cell(map)}

  @doc "Read the current contents of a reference."
  @spec deref(any()) :: any()
  def deref(%ArrayRef{cell: cell}), do: read(cell)
  def deref(%StructRef{cell: cell}), do: read(cell)
  def deref(other), do: other

  @doc "Replace the contents of a reference, returning the same reference."
  @spec write(ArrayRef.t() | StructRef.t(), list() | map()) :: ArrayRef.t() | StructRef.t()
  def write(%ArrayRef{cell: cell} = ref, list) when is_list(list) do
    put(cell, list)
    ref
  end

  def write(%StructRef{cell: cell} = ref, map) when is_map(map) do
    put(cell, map)
    ref
  end

  @doc "Whether a value is an array or struct reference."
  @spec ref?(any()) :: boolean()
  def ref?(%ArrayRef{}), do: true
  def ref?(%StructRef{}), do: true
  def ref?(_other), do: false

  ## Internal cell storage

  @spec new_cell(any()) :: reference()
  defp new_cell(value) do
    cell = make_ref()
    put(cell, value)
    cell
  end

  @spec read(reference()) :: any()
  defp read(cell), do: Process.get({__MODULE__, cell})

  @spec put(reference(), any()) :: :ok
  defp put(cell, value) do
    Process.put({__MODULE__, cell}, value)
    :ok
  end
end
