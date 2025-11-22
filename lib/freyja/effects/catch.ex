defmodule Freyja.Effects.Catch do
  @moduledoc """
  Higher-order Catch effect for exception handling in Hefty computations.

  Based on the Catch elaboration from "Hefty Algebras" paper (Example 3.1).

  ## Overview

  The Catch effect provides exception handling for Hefty computations. It takes
  two computation parameters:
  - `try` - The computation to execute
  - `catch` - The fallback computation if an error occurs

  ## Example

      import Freyja.Effects.Catch

      hefty do
        result <- catch_hefty(
          # Try block - might throw
          hefty do
            x <- Lift.lift(State.get())
            if x < 0 do
              Lift.lift(Throw.throw_error("negative value"))
            else
              Hefty.pure(x * 2)
            end
          end,
          # Catch block - fallback
          Hefty.pure(0)
        )

        Hefty.pure(result)
      end

  ## Elaboration

  The Catch operation is elaborated into first-order effects using the
  `Error.catch_fx` runner effect. The elaboration:

  1. Runs the try computation with error handling
  2. If successful, continues with the result
  3. If error, runs the catch computation

  The control flow decision (success vs error) is encoded as a case statement
  in the elaborated Freer computation.

  ## See Also

  - `Freyja.Effects.Catch.Algebra` - The elaboration algebra
  - `Freyja.Effects.Throw` - First-order throw effects
  """

  import Freyja.Hefty.Sig.DefHeftyStruct

  # The Catch operation struct
  # Fields:
  #   type - Optional type filter (currently unused, for future extension)
  #   handler - Error handler function (error -> Hefty.t())
  def_hefty_struct(Catch, type: :any, handler: nil)

  @doc """
  Create a Catch operation with try computation and error handler function.

  ## Parameters

  - `try_comp` - Hefty computation to attempt
  - `error_handler_fn` - Function `(error -> Hefty.t())` that receives the error
    and returns a Hefty computation for recovery

  ## Returns

  A Hefty.Impure node with the Catch operation and computation forks.

  ## Example

      # Simple default value on error
      result = catch_hefty(
        hefty do
          x <- Lift.lift(computation_that_might_fail())
          Hefty.pure(x)
        end,
        fn _err -> Hefty.pure(:default_value) end
      )

      # Pattern match on error
      result = catch_hefty(
        hefty do ... end,
        fn
          :not_found -> Hefty.pure(:default)
          :timeout -> retry_computation()
          other -> Hefty.pure({:error, other})
        end
      )
  """
  def catch_hefty(try_comp, error_handler_fn) when is_function(error_handler_fn, 1) do
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %Catch{type: :any, handler: error_handler_fn},
      %{
        try: try_comp
        # Note: catch handler is in the Catch struct, not in psi!
      }
    )
  end
end

defmodule Freyja.Effects.Catch.Algebra do
  @moduledoc """
  Algebra for elaborating Catch operations into first-order effects.

  Implements the elaboration from "Hefty Algebras" paper Example 3.1.

  ## Strategy

  The Catch operation is elaborated using a first-order "runner" effect pattern:

  1. Create a `RunCatching` effect that wraps the try computation
  2. The runner handler executes the computation and returns `{:ok, value}` or `{:error, err}`
  3. Use a case statement to branch on the result
  4. Call continuation with appropriate value

  ## The Runner Effect Pattern

  This is a key pattern for elaborating higher-order effects in Hefty algebras:

  **Runner Effect**: A first-order effect that a handler executes to produce an
  inspectable result (like `{:ok, value}` or `{:error, err}`). The algebra creates
  this effect during elaboration, and embeds control flow (case statements) in the
  elaborated Freer computation.

  In this case:
  - Algebra creates a `RunCatching` effect with the (already elaborated) computation
  - Algebra embeds a case statement in the elaborated Freer code to branch on results
  - `RunCatchingHandler` executes the computation and returns `{:ok, value}` or `{:error, err}`
  - The case statement's branches are plain Freer code that execute based on the result

  ## Why Use This Pattern?

  This two-phase approach (elaboration → interpretation) separates concerns:
  - **Algebras** handle structural transformations (creating effects, embedding control flow)
  - **Handlers** handle execution concerns (running computations, propagating state)
  - **Control flow** is encoded as ordinary Elixir code (case statements) in elaborated Freer computations

  Compare this to direct scoped effects (like old `Error.Catch`), where a single handler
  does everything: receives the computation, executes it, inspects the result, and decides
  what to do next. The Hefty approach is more modular - algebras compose independently
  of handlers, and complex higher-order effects can be elaborated into simpler primitives.

  ## State Propagation

  With interposition-based elaboration, state propagates naturally through the
  single top-level interpreter. No special state propagation mechanism needed.
  This implements non-transactional semantics by default - state changes persist
  even when errors occur.

  ## Key Insight

  When this algebra's `elaborate/4` is called, the try and catch computations
  in `psi` are already Freer (not Hefty). The fold has elaborated them bottom-up.

  The algebra just needs to compose these Freer computations using the
  runner effect and a case statement.

  ## Example Elaboration

  Input Hefty:
      Catch.catch(
        hefty do x <- State.get(); Hefty.pure(x) end,
        Hefty.pure(0)
      )

  Elaborated Freer:
      con do
        result <- run_catching(
          con do x <- State.get(); Freer.pure(x) end  # Already Freer!
        )
        case result do
          {:ok, value} -> Freer.pure(value)
          {:error, _} -> Freer.pure(0)  # Already Freer!
        end
      end
  """

  @behaviour Freyja.Hefty.Algebra

  require Logger

  alias Freyja.Effects.Catch.Catch, as: CatchOp
  alias Freyja.Effects.Throw
  alias Freyja.Freer
  alias Freyja.Freer.Interpose

  @impl true
  def handles?(sig) when sig == Freyja.Effects.Catch, do: true
  def handles?(_), do: false

  @impl true
  def elaborate(%CatchOp{handler: error_handler_fn} = _op, psi, k, elaborator) do
    # Extract already-elaborated try computation (Freer)
    try_comp = Map.fetch!(psi, :try)

    # The error handler function is stored in the Catch struct
    # It's NOT in psi, so it won't be pre-elaborated
    # We'll call it dynamically when an error occurs

    # NEW APPROACH: Use interposition to structurally transform the computation
    # Instead of using a runner effect with nested Run.run(), we intercept
    # Error.Throw operations and replace them with handler calls.
    #
    # This is the key difference from the old approach:
    # - No nested interpretation
    # - All effects stay at the same level
    # - Suspensions work automatically because the interception is baked into the structure
    transformed =
      Interpose.interpose_with(
        try_comp,
        # Match only Throw.ThrowOp operations
        fn sig, data ->
          sig == Throw and match?(%Throw.ThrowOp{}, data)
        end,
        fn %Throw.ThrowOp{error: err}, _continuation ->
          # When a throw is encountered:
          # 1. Call the error handler function to get a Hefty computation
          catch_hefty_comp = error_handler_fn.(err)
          # 2. Elaborate the catch computation (it's Hefty, needs elaboration!)
          catch_freer_comp = elaborator.(catch_hefty_comp)
          # 3. Return the catch result directly - DON'T call continuation!
          #    Throw short-circuits, so we discard the continuation
          catch_freer_comp
        end
      )

    # Bind the transformed computation to the outer continuation
    Freer.bind(transformed, k)
  end

  @doc """
  Add this algebra to a computation or builder pipeline.

  ## Examples

      # Start new pipeline
      hefty_computation |> Catch.Algebra.run()

      # Add to existing pipeline
      builder |> Catch.Algebra.run()
  """
  def run(computation_or_builder) do
    Freyja.Run.RunBuilder.add(computation_or_builder, __MODULE__, nil)
  end
end
