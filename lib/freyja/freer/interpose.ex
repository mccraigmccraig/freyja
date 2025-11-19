defmodule Freyja.Freer.Interpose do
  @moduledoc """
  Interposition - recursively transform a Freer computation by intercepting
  and rewriting specific effects while leaving others unchanged.

  Based on Heftia's interposeForBy mechanism (Control.Monad.Hefty.Interpret.hs:229-238).

  ## How It Works

  Interposition walks the computation tree recursively and intercepts operations
  matching a target effect signature. Non-matching operations are reconstructed
  with continuations that preserve the interposition for the rest of the computation.

  This is the key mechanism that enables higher-order effects (like Catch) to
  structurally transform computations before interpretation, without nested
  interpreter runs.

  ## Key Mechanism

  For each operation in the computation tree, we create a wrapped continuation:

      k = fn v ->
        next_comp = Impl.q_apply(q, v)  # Apply original continuation queue
        loop(next_comp)                  # Recursively apply interposition
      end

  This ensures that interposition is preserved throughout the computation tree,
  including across suspension boundaries. When a computation suspends, the
  continuation returned includes the interposition wrapping, so when resumed,
  the interposition is still active.

  ## Comparison to Runner Effect Pattern

  **Old approach (runner effects):**
  - Higher-order effect creates a runner effect
  - RunnerHandler executes computation with nested Run.run()
  - Inspects result, handles success/error
  - Problem: Suspensions escape the nested run, lose context

  **New approach (interposition):**
  - Higher-order effect uses interpose to transform the tree
  - All effects stay at same level after elaboration
  - Single top-level interpreter runs everything
  - Suspensions work automatically - context preserved in structure

  ## Example: Catch with Interposition

      # Transform a computation by intercepting Error.Throw operations
      interpose_with(
        computation,
        Freyja.Effects.Error,
        fn
          %Error.Throw{error: err}, continuation ->
            # Call error handler and bind to continuation
            error_handler.(err) |> elaborate() |> Freer.bind(continuation)
        end
      )

      # The computation tree is transformed structurally:
      # - All Throw operations are replaced with handler calls
      # - Other operations (like Yield) pass through unchanged
      # - Their continuations include the throw-interception logic
      # - When executed, throws are caught even after suspensions

  ## Why This Solves Catch + Coroutine

  Consider: `catch (yield(5) >>= \\x -> throw(x)) handler`

  1. Interpose walks the tree
  2. Encounters `Yield 5` - not a Throw, so reconstructs it
  3. The continuation after yield includes the throw interception
  4. Top-level interpreter sees Yield, returns suspension
  5. When resumed, continuation still has interposition active
  6. The throw is caught!

  Without interposition (old approach):
  1. RunCatchingHandler calls Run.run(try_comp)
  2. Nested run encounters yield, returns suspension
  3. Suspension escapes back to caller
  4. Resume continues, but catch scope is gone
  5. Throw is not caught (BUG!)
  """

  alias Freyja.Freer
  alias Freyja.Freer.{Pure, Impure}
  alias Freyja.Freer.Impl

  @doc """
  Interpose on effects in a Freer computation, intercepting those that match a predicate.

  Recursively walks the computation tree and intercepts operations matching
  the `matcher`, rewriting them using the `handler` function. Non-matching
  operations are reconstructed with continuations that preserve the interposition.

  ## Parameters

  - `computation` - The Freer computation to transform
  - `matcher` - Either:
    - An atom (effect signature module) to match all operations of that signature
    - A function `(sig, data) -> boolean` to match specific operations
  - `handler` - Handler function: `(effect_data, continuation) -> Freer.t()`
    - `effect_data` - The operation data (e.g., `%Error.Throw{error: err}`)
    - `continuation` - Wrapped continuation that preserves interposition
  - `value_handler` - Function to transform final Pure values (default: identity)

  ## Returns

  A transformed Freer computation where all operations matching the `matcher`
  have been rewritten by calling `handler`. Non-matching operations are
  reconstructed with wrapped continuations.

  ## Matcher

  The matcher can be:

  1. **An atom** - matches all operations with that signature:
     ```elixir
     Freyja.Effects.Error  # Matches all Error operations
     ```

  2. **A predicate function** - matches operations where `(sig, data)` returns `true`:
     ```elixir
     fn sig, data ->
       sig == Freyja.Effects.Error and match?(%Error.Throw{}, data)
     end
     ```

  ## Handler Function

  The handler receives:
  1. The effect operation data
  2. A continuation function that preserves interposition

  The handler should return a Freer computation. Common patterns:

  ```elixir
  # Replace with a value (ignore continuation)
  fn effect_data, _k -> Freer.pure(some_value) end

  # Call handler and continue
  fn effect_data, k ->
    result = handle_effect(effect_data)
    k.(result)
  end

  # Do computation and bind to continuation
  fn effect_data, k ->
    computation = build_replacement(effect_data)
    Freer.bind(computation, k)
  end
  ```

  ## Examples

      # Match all operations of a signature
      interpose(
        computation,
        Freyja.Effects.Error,
        fn %Error.Throw{}, _k -> Freer.pure(:default_value) end
      )

      # Match only specific operations using a predicate
      interpose(
        computation,
        fn sig, data ->
          sig == Freyja.Effects.Error and match?(%Error.Throw{}, data)
        end,
        fn %Error.Throw{error: err}, k ->
          # Only intercept Throw, let other Error ops pass through
          handle_error(err) |> Freer.bind(k)
        end
      )

      # Match based on operation data
      interpose(
        computation,
        fn sig, %State.Get{tag: tag} ->
          sig == Freyja.Effects.State and tag == :critical
        end,
        fn %State.Get{}, k ->
          Logger.warn("Critical state access!")
          k.(current_state)
        end
      )
  """
  @spec interpose(
          Freer.t(),
          atom | (atom, any -> boolean),
          (any, (any -> Freer.t()) -> Freer.t()),
          (any -> Freer.t())
        ) :: Freer.t()
  def interpose(computation, matcher, handler, value_handler \\ &Freer.pure/1) do
    # Convert matcher to a predicate function for uniform handling
    predicate =
      case matcher do
        m when is_atom(m) ->
          # Simple signature matching
          fn sig, _data -> sig == m end

        m when is_function(m, 2) ->
          # Already a predicate function
          m
      end

    # Define the recursive loop as a self-referential function
    # We need to pass loop_fn to itself so it can call itself recursively
    loop = fn comp, loop_fn ->
      case comp do
        # Base case: reached a Pure value
        %Pure{val: x} ->
          # Apply value handler (typically just returns Pure)
          value_handler.(x)

        # Recursive case: found an Impure operation
        %Impure{sig: sig, data: u, q: q} ->
          # Create wrapped continuation that preserves interposition
          # This is the KEY to how interposition works across suspensions!
          #
          # When this continuation is called (e.g., after a suspension is resumed),
          # it will:
          # 1. Apply the original continuation queue to get the next computation
          # 2. Recursively apply interposition to that next computation
          #
          # This means the interposition is "baked into" the continuation structure
          k = fn v ->
            next_comp = Impl.q_apply(q, v)
            loop_fn.(next_comp, loop_fn)
          end

          # Check if this operation matches using the predicate
          if predicate.(sig, u) do
            # Match! Call the handler with the effect data and wrapped continuation
            # The handler decides what to do - might call k, might not
            handler.(u, k)
          else
            # No match: reconstruct the operation with the wrapped continuation
            # The continuation k replaces the original queue q
            # This is critical: non-matching effects pass through, but their
            # continuations are wrapped to preserve interposition for what comes after
            %Impure{sig: sig, data: u, q: [k]}
          end
      end
    end

    # Start the recursive transformation
    # We pass loop to itself so it can recurse
    loop.(computation, loop)
  end

  @doc """
  Interposition with default value handler (identity).

  Convenience function that calls `interpose/4` with the default value handler
  that just returns `Freer.pure/1`.

  This is the most common case - you want to intercept and rewrite specific
  effects, but leave final Pure values unchanged.

  ## Parameters

  - `computation` - The Freer computation to transform
  - `matcher` - Either an atom (signature) or a predicate function `(sig, data) -> boolean`
  - `handler` - Handler function: `(effect_data, continuation) -> Freer.t()`

  ## Examples

      # Intercept all Error operations
      interpose_with(
        computation,
        Freyja.Effects.Error,
        fn %Error.Throw{}, _k -> Freer.pure(:caught) end
      )

      # Intercept only specific Error.Throw operations
      interpose_with(
        computation,
        fn sig, data ->
          sig == Freyja.Effects.Error and match?(%Error.Throw{}, data)
        end,
        fn %Error.Throw{error: err}, k ->
          handle_throw(err) |> Freer.bind(k)
        end
      )
  """
  @spec interpose_with(
          Freer.t(),
          atom | (atom, any -> boolean),
          (any, (any -> Freer.t()) -> Freer.t())
        ) :: Freer.t()
  def interpose_with(computation, matcher, handler) do
    interpose(computation, matcher, handler, &Freer.pure/1)
  end
end
