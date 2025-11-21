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
  alias Freyja.Freer.Sig.ISendable

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

  # this is terrible - but there's no way of specifying
  # the ISendable Protocol constraint in typespecs afaics
  @type freer() :: %Pure{} | %Impure{} | any

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

  # this allows plain Sendable structs to behave just like Freer values
  # which have been sent with `etaf` / `send_effect`
  def bind(sendable, k), do: ISendable.send(sendable) |> bind(k)

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

defimpl Freyja.Freer.Sig.ISendable, for: Freyja.Freer.Pure do
  def send(eff), do: eff
end

defimpl Freyja.Freer.Sig.ISendable, for: Freyja.Freer.Impure do
  def send(eff), do: eff
end

defimpl Freyja.Freer.Sig.ISendable, for: Any do
  def send(eff) do
    raise ArgumentError,
      message:
        "#{__MODULE__}.send - not Sendable: #{inspect(eff, pretty: true)} - " <>
          "do you need to return() ?"
  end
end
