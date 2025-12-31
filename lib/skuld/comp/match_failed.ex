defmodule Skuld.Comp.MatchFailed do
  @moduledoc """
  Represents a pattern match failure in a `comp` block.

  When a `<-` binding in a `comp` block with an `else` clause fails to match,
  a `%MatchFailed{}` is thrown via `Throw.throw/1`. The `else` handler can
  then pattern match on the unmatched value to provide recovery.

  ## Example

      comp do
        {:ok, x} <- maybe_returns_error()
        return(x)
      else
        {:error, reason} -> return({:failed, reason})
      end

  If `maybe_returns_error()` returns `{:error, :not_found}`, the pattern
  `{:ok, x}` fails to match, and `%MatchFailed{value: {:error, :not_found}}`
  is thrown. The else handler catches this and matches against the value.

  ## Uncaught Match Failures

  If a match failure is not handled by the else clause (no pattern matches),
  it propagates as `%Comp.Throw{error: %MatchFailed{value: ...}}`.
  """

  defstruct [:value]

  @type t :: %__MODULE__{value: term()}
end
