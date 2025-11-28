defmodule Freyja.Freer do
  @moduledoc """
  A Freer Monad with extensible effects, based on the paper:
  https://okmij.org/ftp/Haskell/extensible/more.pdf

  with some Elixir inspiration from:
  https://github.com/aemaeth-me/freer
  https://github.com/bootstarted/effects
  """
  require Logger

  alias Freyja.Freer
  alias Freyja.Freer.Sig.ISignature

  # Freer values are %Pure{} and %Impure{}

  defmodule Pure do
    defstruct val: nil

    @type t :: %__MODULE__{
            val: any
          }
  end

  defmodule Impure do
    defstruct sig: nil, data: nil, q: []

    @type t :: %__MODULE__{
            sig: atom,
            data: any,
            # should be list((any->freer))
            q: list((any -> any))
          }
  end

  @type freer() :: %Pure{} | %Impure{}
  @type t() :: freer()

  def freer?(%Pure{}), do: true
  def freer?(%Impure{}), do: true
  def freer?(_), do: false

  # now the Freer functions

  @spec pure(any) :: freer
  def pure(x), do: %Pure{val: x}

  @doc """
  send an effect data-structure for interpretation

  `sig` identifies the operations module definint the effect signature -
  (the set of operation functions available for the effect)
  """
  @spec send_effect(any, atom) :: freer
  def send_effect(fa, sig) do
    %Impure{sig: sig, data: fa, q: [&Freer.pure/1]}
  end

  @spec send_effect(any) :: freer
  def send_effect(fa) do
    sig = ISignature.signature(fa)
    %Impure{sig: sig, data: fa, q: [&Freer.pure/1]}
  end

  @doc """
  the same as `send_effect` - `etaf` is the name of the function in the
  `more.pdf` paper
  """
  @spec etaf(any, atom) :: freer
  def etaf(fa, sig), do: send_effect(fa, sig)

  @spec return(any) :: freer
  def return(x), do: pure(x)

  @spec bind(freer, (any -> freer)) :: freer
  def bind(%Pure{val: x}, k), do: k.(x)

  def bind(%Impure{sig: sig, data: u, q: q}, k),
    do: %Impure{sig: sig, data: u, q: Freyja.Freer.Impl.q_append(q, k)}

  @doc """
  Monadic bind operator (>>=/2).

  Infix version of `bind/2` for more readable computation chains.

  ## Examples

      use Freyja.Freer.Operators

      computation =
        some_operation()
        ~>> fn x ->
          another_operation(x)
          ~>> fn y ->
            pure(x + y)
          end
        end
  """
  @spec freer() ~>> (any -> freer()) :: freer()
  def computation ~>> continuation do
    bind(computation, continuation)
  end
end
