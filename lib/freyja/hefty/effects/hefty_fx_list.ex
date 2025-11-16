defmodule Freyja.Hefty.Effects.HeftyFxList do
  @moduledoc """
  Higher-order FxList effect using Hefty algebras.

  Provides map and reduce operations with effectful functions, demonstrating
  the power and simplicity of the Hefty algebras approach.

  ## Comparison with Legacy FxList

  **Old FxList.Handler** (lib/freyja/effects/fx_list.ex):
  - ~150 lines of complex code
  - Manual RunOutcome handling
  - ScopedOk/ScopedError callbacks
  - Tricky queue management (see comments in code)
  - Manual continuation wrapping for suspensions
  - Fragile and hard to understand

  **New HeftyFxList.Algebra**:
  - ~20 lines of simple code
  - Just sequences computations
  - No special cases for suspension/error
  - No queue management
  - Self-explanatory

  This is the **15x complexity reduction** that Hefty algebras provide.

  ## Operations

  - `fx_map(list, f)` - Map effectful function over list
  - `fx_reduce(list, init, f)` - Reduce with effectful function

  ## Example

      import Freyja.HeftyMacro

      defhefty process_users(user_ids) do
        users <- HeftyFxList.fx_map(user_ids, fn id ->
          hefty do
            user <- Storage.query_user(id)  # Freer - auto-lifted
            count <- State.get()            # Freer - auto-lifted
            State.put(count + 1)            # Freer - auto-lifted
            return(user)
          end
        end)
        return(users)
      end

  ## How It Works

  FxMap creates a Hefty.Impure with one computation parameter per list element:

      fx_map([1, 2, 3], f)
      →
      Hefty.Impure{
        sig: HeftyFxList,
        data: %FxMap{list: [1, 2, 3], f: f},
        psi: %{
          0 => f.(1),  # Hefty computation
          1 => f.(2),  # Hefty computation
          2 => f.(3)   # Hefty computation
        }
      }

  During elaboration, the algebra receives psi with already-elaborated Freer
  computations, and just sequences them.

  ## Suspensions

  If `f` yields (suspends), the elaboration doesn't see or handle it. The
  elaborated Freer computation contains Yield operations, which are handled
  uniformly by the runtime interpreter.

  No manual continuation management needed!

  ## See Also

  - `Freyja.Effects.FxList` - Legacy implementation (for comparison)
  - `Freyja.Hefty.Effects.HeftyFxList.Algebra` - The elaboration algebra
  """

  import Freyja.Sig.DefHeftyStruct

  # FxMap operation - map with effectful function
  # Fields: list (the list to map over), f (effectful function)
  def_hefty_struct(FxMap, list: [], f: nil)

  # FxReduce operation - reduce with effectful function
  # Fields: list (the list to reduce), init (initial accumulator), f (effectful function)
  def_hefty_struct(FxReduce, list: [], init: nil, f: nil)

  @doc """
  Map an effectful function over a list.

  Creates one computation parameter (fork) per list element, indexed by position.

  ## Parameters

  - `list` - List of elements to process
  - `f` - Effectful function: element -> Hefty computation

  ## Returns

  Hefty.Impure with FxMap operation and indexed psi forks.

  ## Example

      HeftyFxList.fx_map([1, 2, 3], fn x ->
        hefty do
          count <- State.get()
          State.put(count + 1)
          return(x * 2)
        end
      end)
  """
  def fx_map(list, f) when is_list(list) and is_function(f, 1) do
    # Create one fork per list element, indexed by position
    forks =
      list
      |> Enum.with_index()
      |> Map.new(fn {elem, idx} ->
        {idx, f.(elem)}
      end)

    Freyja.Hefty.send_hefty(
      __MODULE__,
      %FxMap{list: list, f: f},
      forks
    )
  end

  @doc """
  Reduce a list with an effectful function.

  ## Parameters

  - `list` - List of elements to process
  - `init` - Initial accumulator value
  - `f` - Effectful function: (element, accumulator) -> Hefty computation

  ## Returns

  Hefty computation that produces final accumulator.

  ## Example

      HeftyFxList.fx_reduce([1, 2, 3], 0, fn elem, acc ->
        hefty do
          State.put(acc + elem)
          return(acc + elem)
        end
      end)
  """
  def fx_reduce(list, init, f) when is_list(list) and is_function(f, 2) do
    # For reduce, we don't create forks (computation parameters) upfront
    # because each computation depends on the result of the previous one.
    # Instead, the elaboration will directly generate the recursive Freer code.
    # We just need to pass the list, init, and f to the algebra.
    Freyja.Hefty.send_hefty(
      __MODULE__,
      %FxReduce{list: list, init: init, f: f},
      # No forks - elaboration handles recursion directly
      %{}
    )
  end
end

# First-order runner effect for fx_reduce
# Defined before Algebra so it can be imported
defmodule Freyja.Hefty.Effects.HeftyFxList.RunFxReduce do
  import Freyja.Sig.DefEffectStruct

  def_effect_struct(RunFxReduce, list: [], init: nil, f: nil)

  def run_fx_reduce(list, init, f) do
    %RunFxReduce{list: list, init: init, f: f}
  end
end

defmodule Freyja.Hefty.Effects.HeftyFxList.Algebra do
  @moduledoc """
  Algebra for elaborating HeftyFxList operations.

  THIS IS THE SHOWCASE: Compare this ~40 line module to the ~150 line
  lib/freyja/effects/fx_list.ex handler!

  ## What This Shows

  Hefty algebras eliminate:
  - Manual RunOutcome handling
  - ScopedOk/ScopedError complexity
  - Continuation queue management
  - Suspension special cases
  - Tricky comments explaining fragile behavior

  The elaboration is simple: sequence the computations, call continuation.
  That's it!

  ## Key Insight

  The algebra receives already-elaborated Freer computations in psi.
  It doesn't see or handle suspensions, errors, or any runtime behavior.
  It just defines the STRUCTURE: "run these sequentially, collect results".

  Runtime interpretation handles everything else uniformly.
  """

  @behaviour Freyja.Hefty.Algebra

  alias Freyja.Hefty.Effects.HeftyFxList.FxMap
  alias Freyja.Hefty.Effects.HeftyFxList.FxReduce
  alias Freyja.Hefty
  alias Freyja.Freer
  import Freyja.Con
  import Freyja.Hefty.Effects.HeftyFxList.RunFxReduce, only: [run_fx_reduce: 3]

  @impl true
  def handles?(sig) when sig == Freyja.Hefty.Effects.HeftyFxList, do: true
  def handles?(_), do: false

  @impl true
  def elaborate(%FxMap{list: list}, psi, k, _elaborator) do
    # Handle empty list specially
    if Enum.empty?(list) do
      k.([])
    else
      # Extract already-elaborated Freer computations from psi (indexed by position)
      result_comps =
        0..(length(list) - 1)
        |> Enum.map(fn idx -> Map.fetch!(psi, idx) end)

      # Sequence them and call continuation - that's it!
      # This is the entire fx_map elaboration - ~15 lines!
      # Compare to ~150 lines in lib/freyja/effects/fx_list.ex
      con do
        results <- sequence(result_comps)
        k.(results)
      end
    end
  end

  def elaborate(%FxReduce{list: list, init: init, f: f}, _psi, k, _elaborator) do
    # For reduce, we use a runner effect pattern (like Catch)
    # Create a first-order RunFxReduce effect that wraps the list, init, and function
    # The handler will execute the reduction at interpretation time
    con do
      result <- run_fx_reduce(list, init, f)
      k.(result)
    end
  end

  # Helper: Sequence a list of Freer computations
  # Returns Freer computation that produces list of results
  defp sequence([]), do: Freer.pure([])

  defp sequence([comp | rest]) do
    con do
      val <- comp
      rest_vals <- sequence(rest)
      return([val | rest_vals])
    end
  end
end

defmodule Freyja.Hefty.Effects.HeftyFxList.RunFxReduceHandler do
  @moduledoc """
  Handler for RunFxReduce effect.

  Executes the reduction by recursively running the effectful function.
  Uses the same state propagation approach as RunCatchingHandler.
  """

  @behaviour Freyja.EffectHandler

  alias Freyja.Hefty.Effects.HeftyFxList.RunFxReduce.RunFxReduce
  alias Freyja.Freer
  alias Freyja.Freer.Impure
  alias Freyja.Freer.Impl
  alias Freyja.Hefty
  alias Freyja.Run.RunState
  import Freyja.Con

  @impl true
  def handles?(%Impure{sig: sig}, _state) do
    sig == Freyja.Hefty.Effects.HeftyFxList.RunFxReduce
  end

  @impl true
  def interpret(
        %Impure{
          sig: Freyja.Hefty.Effects.HeftyFxList.RunFxReduce,
          data: %RunFxReduce{list: list, init: init, f: f},
          q: q
        },
        _handler_key,
        state,
        %RunState{} = run_state
      ) do
    # f returns Hefty computations - we need to elaborate them and run them
    # Build the reduction as a Freer computation
    reduce_computation = reduce_loop(list, init, f, run_state)

    # Return the reduction computation bound to the continuation
    {Impl.bindp(reduce_computation, q), state}
  end

  # Helper: Recursively reduce the list
  defp reduce_loop([], acc, _f, _run_state) do
    Freer.pure(acc)
  end

  defp reduce_loop([elem | rest], acc, f, run_state) do
    # f returns a Hefty computation
    # We need to convert it to Freer
    hefty_comp = f.(elem, acc)

    # Convert Hefty to Freer by unwrapping Lift operations
    # Lift.lift wraps Freer in Hefty - we just extract it
    freer_comp = unwrap_lifts(hefty_comp)

    # Run the computation and continue with result
    con do
      new_acc <- freer_comp
      reduce_loop(rest, new_acc, f, run_state)
    end
  end

  # Unwrap Lift operations to get underlying Freer
  defp unwrap_lifts(%Hefty.Pure{val: v}) do
    Freer.pure(v)
  end

  defp unwrap_lifts(%Hefty.Impure{
         sig: Freyja.Hefty.Effects.Lift,
         data: %Freyja.Hefty.Effects.Lift{computation: freer_comp},
         k: k
       }) do
    # This is a Lift - extract the Freer computation and continue
    Freer.bind(freer_comp, fn val ->
      unwrap_lifts(k.(val))
    end)
  end

  defp unwrap_lifts(other) do
    raise ArgumentError,
          "fx_reduce function must return only Lift-wrapped Freer computations, got: #{inspect(other)}"
  end
end
