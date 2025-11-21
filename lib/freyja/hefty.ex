defmodule Freyja.Hefty do
  @moduledoc """
  Hefty Trees - computation type for higher-order algebraic effects.

  Based on "Hefty Algebras: Modular Elaboration of Higher-Order Algebraic Effects"
  (Poulsen & van der Rest, POPL 2023).

  ## Overview

  A Hefty tree represents computations with higher-order operations - operations that
  take other computations as parameters. Examples include:
  - `catch(try_computation, catch_computation)` - exception handling
  - `local(modifier, computation)` - scoped environment modification
  - `fx_map(list, f)` - map with effectful function

  Hefty trees are elaborated into Freer computations (first-order effects only)
  through a catamorphism (fold). The elaboration phase transforms higher-order
  operations into sequential first-order operations.

  ## Pipeline

      Hefty H A --elaborate--> Freer Δ A --interpret--> Result

  ## Structure

  A Hefty tree is either:
  - `Pure{val}` - A terminal value
  - `Impure{sig, data, psi, k}` - A higher-order operation node

  Where:
  - `sig` - Effect signature module (identifies which effect)
  - `data` - Operation struct (e.g., %Catch{}, %Local{})
  - `psi` - Computation parameters (forks) - map from keys to Hefty trees
  - `k` - Continuation function: result -> Hefty

  ## Key Differences from Freer

  - **Freer**: Operations have continuations (queue), no computation parameters
  - **Hefty**: Operations have computation parameters (psi) AND continuations

  The computation parameters (`psi`) are the "higher-order" part - they're
  computations that will be elaborated before the operation is transformed.

  ## Example

      # Create a Catch operation with two computation parameters
      catch_hefty = send_hefty(
        Catch,
        %Catch{},
        %{
          try: hefty_computation_1,
          catch: hefty_computation_2
        }
      )

      # During elaboration, both computations in psi will be elaborated first,
      # then the Catch algebra will receive the elaborated Freer computations

  ## Monad Laws

  Hefty forms a monad with `pure` and `bind`:

      # Left identity: pure(x) >>= f ≡ f(x)
      bind(pure(x), f) == f.(x)

      # Right identity: m >>= pure ≡ m
      bind(m, &pure/1) == m

      # Associativity: (m >>= f) >>= g ≡ m >>= (λx -> f(x) >>= g)
      bind(bind(m, f), g) == bind(m, fn x -> bind(f.(x), g) end)
  """

  alias __MODULE__.Pure
  alias __MODULE__.Impure

  defmodule Pure do
    @moduledoc """
    Terminal value in a Hefty computation.

    Represents a computation that immediately returns a value with no effects.
    """
    defstruct [:val]

    @type t :: %__MODULE__{val: any}
  end

  defmodule Impure do
    @moduledoc """
    Higher-order effect operation node in a Hefty computation.

    ## Fields

    - `sig` - Effect signature module (atom identifying the effect)
    - `data` - Operation struct containing operation-specific data
    - `psi` - Computation parameters (forks) - map from fork keys to Hefty trees
    - `k` - Continuation function expecting the operation's result

    ## The psi Map (Computation Parameters)

    The `psi` map contains the computation parameters for higher-order operations.
    These are the "sub-computations" that the operation manages.

    Examples:
    - `Catch`: `%{try: hefty_tree_1, catch: hefty_tree_2}`
    - `Local`: `%{comp: hefty_tree}`
    - `FxMap`: `%{0 => hefty_tree_1, 1 => hefty_tree_2, ...}` (indexed by position)

    During elaboration, all computations in `psi` are recursively elaborated
    BEFORE the operation's algebra is applied. The algebra receives already-elaborated
    Freer computations in the psi map.

    ## The Continuation

    The continuation `k` is a function that takes the operation's result and
    returns the next Hefty computation. This is composed during bind operations.
    """
    defstruct [:sig, :data, :psi, :k]

    @type t :: %__MODULE__{
            sig: atom,
            data: struct,
            psi: %{any => Pure.t() | t()},
            k: (any -> Pure.t() | t())
          }
  end

  @type t :: Pure.t() | Impure.t() | any

  @doc """
  Create a pure Hefty computation that immediately returns a value.

  ## Examples

      iex> Freyja.Hefty.pure(42)
      %Freyja.Hefty.Pure{val: 42}

      iex> Freyja.Hefty.pure("hello")
      %Freyja.Hefty.Pure{val: "hello"}
  """
  @spec pure(any) :: Pure.t()
  def pure(x), do: %Pure{val: x}

  @doc """
  Alias for `pure/1`. Returns a pure Hefty computation.

  Provided for consistency with Freer monad terminology.

  ## Examples

      iex> Freyja.Hefty.return(42)
      %Freyja.Hefty.Pure{val: 42}
  """
  @spec return(any) :: Pure.t()
  def return(x), do: pure(x)

  @doc """
  Monadic bind operation for Hefty computations.

  Sequences two computations: runs the first, passes its result to the
  continuation function to get the second computation.

  ## Type Signature (pseudo-Haskell)

      bind :: Hefty h a -> (a -> Hefty h b) -> Hefty h b

  ## Cases

  1. **Pure bind**: If the first computation is pure, immediately apply the continuation
  2. **Impure bind**: If the first computation is impure, compose the continuations

  ## Examples

      # Left identity: pure(x) >>= f == f(x)
      iex> Freyja.Hefty.bind(Freyja.Hefty.pure(5), fn x -> Freyja.Hefty.pure(x * 2) end)
      %Freyja.Hefty.Pure{val: 10}

      # Right identity: m >>= pure == m
      iex> m = Freyja.Hefty.pure(42)
      iex> Freyja.Hefty.bind(m, &Freyja.Hefty.pure/1)
      %Freyja.Hefty.Pure{val: 42}

      # Continuation composition with operations
      iex> op = Freyja.Hefty.send_hefty(:TestSig, %{}, %{})
      iex> result = Freyja.Hefty.bind(op, fn x -> Freyja.Hefty.pure(x + 1) end)
      iex> result.k.(5)
      %Freyja.Hefty.Pure{val: 6}
  """
  @spec bind(t(), (any -> t())) :: t()
  def bind(%Pure{val: x}, k), do: k.(x)

  def bind(%Impure{sig: sig, data: data, psi: psi, k: cont}, k2) do
    # Compose continuations: first run cont, then run k2
    %Impure{
      sig: sig,
      data: data,
      psi: psi,
      k: fn x -> bind(cont.(x), k2) end
    }
  end

  # Catch-all: Use IHeftySendable protocol to convert to Hefty
  # This enables auto-lifting of Freer effects
  def bind(other, k) do
    hefty = Freyja.Hefty.Sig.IHeftySendable.send_to_hefty(other)
    bind(hefty, k)
  end

  @doc """
  Create a higher-order operation node with computation parameters.

  This is the primitive for creating Hefty operations. Higher-order effects
  use this to create operation nodes with their computation parameters (forks).

  ## Parameters

  - `sig` - Effect signature module (atom)
  - `operation` - Operation struct with operation-specific data
  - `forks` - Map of computation parameters (fork_key -> Hefty computation)

  The continuation is initialized to `&pure/1` (identity continuation).

  ## Examples

      # Operation with no computation parameters
      iex> result = Freyja.Hefty.send_hefty(:State, %{op: :get}, %{})
      iex> result.sig
      :State
      iex> result.data
      %{op: :get}
      iex> result.psi
      %{}

      # Catch operation with two computation parameters
      iex> try_comp = Freyja.Hefty.pure(42)
      iex> catch_comp = Freyja.Hefty.pure(0)
      iex> result = Freyja.Hefty.send_hefty(:Catch, %{}, %{try: try_comp, catch: catch_comp})
      iex> result.sig
      :Catch
      iex> result.psi[:try]
      %Freyja.Hefty.Pure{val: 42}
      iex> result.psi[:catch]
      %Freyja.Hefty.Pure{val: 0}

      # FxMap with indexed computation parameters
      iex> comps = [Freyja.Hefty.pure(1), Freyja.Hefty.pure(2), Freyja.Hefty.pure(3)]
      iex> forks = Enum.with_index(comps) |> Map.new(fn {c, i} -> {i, c} end)
      iex> result = Freyja.Hefty.send_hefty(:FxMap, %{list: [1, 2, 3]}, forks)
      iex> result.sig
      :FxMap
      iex> result.psi[0]
      %Freyja.Hefty.Pure{val: 1}
      iex> result.psi[1]
      %Freyja.Hefty.Pure{val: 2}
      iex> result.psi[2]
      %Freyja.Hefty.Pure{val: 3}
  """
  @spec send_hefty(atom, struct, %{any => t()}) :: Impure.t()
  def send_hefty(sig, operation, forks \\ %{}) do
    %Impure{
      sig: sig,
      data: operation,
      psi: forks,
      k: &pure/1
    }
  end

  @doc """
  Monadic bind operator (>>=/2).

  Infix version of `bind/2` for more readable computation chains.

  ## Examples

      use Freyja.Hefty.Operators

      computation =
        some_operation()
        ~>> fn x ->
          another_operation(x)
          ~>> fn y ->
            pure(x + y)
          end
        end
  """
  @spec t() ~>> (any -> t()) :: t()
  def computation ~>> continuation do
    bind(computation, continuation)
  end
end
