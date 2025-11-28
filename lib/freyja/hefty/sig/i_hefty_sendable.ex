defprotocol Freyja.Hefty.Sig.IHeftySendable do
  @moduledoc """
  Protocol for converting values to Hefty computations.

  This protocol enables automatic lifting of Freer (first-order) effects into
  Hefty (higher-order) computations, allowing seamless mixing of both in `hefty`
  blocks.

  ## Design Philosophy

  This protocol:
  - Determines what can be used in Hefty computations
  - Enables auto-lifting of Freer effects via Lift
  - Throws clear errors for unsupported types (NO Any fallback!)

  ## Implementations

  - `Hefty.Pure` and `Hefty.Impure` - Identity (already Hefty)
  - `Freer.Pure` and `Freer.Impure` - Auto-lift via Lift.lift
  - Other types - NO fallback, raises Protocol.UndefinedError

  ## Usage

  You typically won't call this protocol directly. Instead, it's used by:
  - `Hefty.bind/2` catch-all clause for auto-lifting
  - The `hefty` macro for seamless first-order + higher-order composition

  ## Example

      # In Hefty.bind
      def bind(other, k) do
        hefty = Freyja.Hefty.Sig.IHeftySendable.send_to_hefty(other)
        bind(hefty, k)
      end

      # When you write:
      hefty do
        x <- State.get()  # Returns Freer.Impure
        Hefty.pure(x)
      end

      # The bind call triggers protocol:
      # Hefty.bind(State.get(), fn x -> ... end)
      # → send_to_hefty(Freer.Impure)
      # → Lift.lift(State.get())
      # → Hefty.Impure with Lift operation

  ## Error Handling

  If a value doesn't implement IHeftySendable, you'll get a clear error:

      Protocol.UndefinedError: protocol Freyja.Hefty.Sig.IHeftySendable not implemented
      for %SomeStruct{} of type SomeStruct

  This helps catch bugs where:
  - You forgot to implement the protocol
  - You're using the wrong computation type
  - You have a struct that should be an effect but isn't properly defined

  ## See Also

  - `Freyja.Effects.Lift` - Bridges Freer to Hefty
  - `Freyja.Hefty.bind/2` - Uses protocol for auto-lifting
  """

  @doc """
  Convert a value to a Hefty computation.

  ## For Hefty Types

  Returns the value unchanged (already Hefty).

  ## For Freer Types

  Wraps in Lift operation to bridge first-order to higher-order.

  ## For Unsupported Types

  Raises `Protocol.UndefinedError` with clear message.

  ## Parameters

  - `value` - The value to convert (Hefty, Freer, or other)

  ## Returns

  `Hefty.t()` - Either `Hefty.Pure` or `Hefty.Impure`

  ## Raises

  `Protocol.UndefinedError` if the value's type doesn't implement the protocol.

  ## Examples

      # Hefty nodes - identity
      iex> Freyja.Hefty.Sig.IHeftySendable.send_to_hefty(Hefty.pure(42))
      %Freyja.Hefty.Pure{val: 42}

      # Freer.Pure - converts directly to Hefty.Pure (optimization)
      iex> freer_pure = Freer.pure(42)
      iex> Freyja.Hefty.Sig.IHeftySendable.send_to_hefty(freer_pure)
      %Freyja.Hefty.Pure{val: 42}

      # Freer.Impure - lifts via Lift operation
      iex> freer_impure = Freer.send(Freyja.Effects.State, %Freyja.Effects.State.Get{})
      iex> result = Freyja.Hefty.Sig.IHeftySendable.send_to_hefty(freer_impure)
      iex> match?(%Freyja.Hefty.Impure{sig: Freyja.Hefty.Effects.Lift}, result)
      true

      # Unsupported type - error
      iex> Freyja.Hefty.Sig.IHeftySendable.send_to_hefty(%{not: :a_computation})
      ** (Protocol.UndefinedError) protocol Freyja.Hefty.Sig.IHeftySendable not implemented...
  """
  @spec send_to_hefty(any) :: Freyja.Hefty.t()
  def send_to_hefty(value)
end

# Hefty.Pure - already Hefty, return as-is
defimpl Freyja.Hefty.Sig.IHeftySendable, for: Freyja.Hefty.Pure do
  @moduledoc """
  Hefty.Pure is already a Hefty computation.

  Returns the Pure node unchanged.
  """

  def send_to_hefty(pure), do: pure
end

# Hefty.Impure - already Hefty, return as-is
defimpl Freyja.Hefty.Sig.IHeftySendable, for: Freyja.Hefty.Impure do
  @moduledoc """
  Hefty.Impure is already a Hefty computation.

  Returns the Impure node unchanged.
  """

  def send_to_hefty(impure), do: impure
end

# Freer.Pure - lift to Hefty
defimpl Freyja.Hefty.Sig.IHeftySendable, for: Freyja.Freer.Pure do
  @moduledoc """
  Freer.Pure is lifted to Hefty.

  Uses Lift.lift which optimizes: Freer.Pure → Hefty.Pure directly
  (no Lift operation needed for pure values).
  """

  alias Freyja.Effects.Lift

  def send_to_hefty(freer_pure) do
    Lift.lift(freer_pure)
  end
end

# Freer.Impure - lift to Hefty via Lift
defimpl Freyja.Hefty.Sig.IHeftySendable, for: Freyja.Freer.Impure do
  @moduledoc """
  Freer.Impure is a first-order effect that needs lifting to Hefty.

  Wraps the Freer.Impure in a Lift operation to bridge into Hefty land.
  This allows first-order effects (State, Reader, etc.) to be used seamlessly
  in Hefty computations without manual Lift.lift() calls.

  ## Example

      # In a hefty block
      hefty do
        x <- State.get()  # Returns Freer.Impure
        # Protocol auto-lifts: Lift.lift(State.get())
        Hefty.pure(x)
      end
  """

  alias Freyja.Effects.Lift

  def send_to_hefty(freer_impure) do
    Lift.lift(freer_impure)
  end
end
