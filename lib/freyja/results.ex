defprotocol Freyja.Protocols.Result do
  @fallback_to_any true

  @spec type(t) :: atom
  def type(result)

  @spec value(t) :: any
  def value(result)

  @spec short_circuits?(t) :: boolean
  def short_circuits?(result)
end

defmodule Freyja.OkResult do
  @moduledoc """
  Result type for a finished computation
  """
  defstruct value: nil

  @type t :: %__MODULE__{value: any}

  def ok(val), do: %__MODULE__{value: val}
end

defimpl Freyja.Protocols.Result, for: Freyja.OkResult do
  def type(_r), do: Freyja.OkResult
  def value(r), do: r.value
  def short_circuits?(_r), do: false
end

defmodule Freyja.ErrorResult do
  @moduledoc """
  Result type for a computation which is short-circuiting with an error
  """
  defstruct error: nil

  @type t :: %__MODULE__{error: any}

  def error(err), do: %__MODULE__{error: err}
end

defimpl Freyja.Protocols.Result, for: Freyja.ErrorResult do
  def type(_r), do: Freyja.ErrorResult
  def value(r), do: r.error
  def short_circuits?(_r), do: true
end

defmodule Freyja.SuspendResult do
  @moduledoc """
  Result type for a computation which is yielding a value to a caller,
  with the expectation that the caller will supply a return value to
  continue the computation
  """
  defstruct value: nil, continuation: nil

  @type t :: %__MODULE__{value: any, continuation: (any -> any)}

  def yield(val, continuation),
    do: %__MODULE__{value: val, continuation: continuation}
end

defimpl Freyja.Protocols.Result, for: Freyja.SuspendResult do
  def type(_r), do: Freyja.SuspendResult
  def value(r), do: r.value
  def short_circuits?(_r), do: true
end

# default implementation allows us to detect non-Result values
defimpl Freyja.Protocols.Result, for: Any do
  def type(_r), do: nil
  def value(r), do: r
  def short_circuits?(_r), do: false
end

defmodule Freyja.Result do
  alias Freyja.OkResult
  alias Freyja.ErrorResult
  alias Freyja.SuspendResult

  @type result :: OkResult.t() | ErrorResult.t() | SuspendResult.t()
end
