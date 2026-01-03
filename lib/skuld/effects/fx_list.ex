defmodule Skuld.Effects.FxList do
  @moduledoc """
  FxList effect for Skuld - effectful list operations.

  Provides map and reduce operations with effectful functions.
  Unlike Freyja's Hefty-based FxList, this is a simple module
  that sequences computations - no special handler needed.

  ## Operations

  - `fx_map(list, f)` - Map effectful function over list
  - `fx_reduce(list, init, f)` - Reduce with effectful function
  - `fx_each(list, f)` - Execute effectful function for each element (returns :ok)
  - `fx_filter(list, pred)` - Filter with effectful predicate

  ## Example

      import Skuld.Syntax

      defcomp process_users(user_ids) do
        users <- FxList.fx_map(user_ids, fn id ->
          comp do
            user <- fetch_user(id)
            count <- State.get()
            _ <- State.put(count + 1)
            return(user)
          end
        end)
        return(users)
      end

  ## Performance Warning: Large Lists

  FxList builds continuation chains proportional to list length. For large
  lists (10,000+ elements), this causes memory/cache pressure that degrades
  performance to ~O(n^1.3) instead of O(n).

  **Benchmarks show:**
  - 1,000 elements: ~0.2µs per operation
  - 10,000 elements: ~0.4µs per operation (2x slower per-op)
  - 100,000 elements: ~0.8µs per operation (4x slower per-op)

  **For large iteration counts, use `Skuld.Effects.Yield` instead:**

      # Yield-based approach: O(n) scaling at any size
      def iteration_loop() do
        comp do
          n <- State.get()
          _ <- State.put(n + 1)
          _ <- Yield.yield(:ok)
          iteration_loop()
        end
      end

      # Run N iterations with constant per-op cost
      iteration_loop()
      |> Yield.with_handler()
      |> State.with_handler(0)
      |> Yield.run_with_driver(fn _yielded ->
        if iterations_remaining > 0 do
          {:continue, :ok}
        else
          {:stop, :done}
        end
      end)

  The Yield approach maintains ~0.17µs per operation regardless of N,
  achieving 2-8x speedup over FxList at large scales.

  **Rule of thumb:** Use FxList for lists under ~5,000 elements.
  For larger iteration counts, use Yield-based coroutines.
  """

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @doc """
  Map an effectful function over a list.

  Returns a computation that produces a list of results.

  ## Example

      FxList.fx_map([1, 2, 3], fn x ->
        comp do
          count <- State.get()
          _ <- State.put(count + 1)
          return(x * 2)
        end
      end)
      # => computation returning [2, 4, 6]
  """
  @spec fx_map(list(), (term() -> Types.computation())) :: Types.computation()
  def fx_map([], _f), do: Comp.pure([])

  def fx_map([head | tail], f) do
    Comp.bind(f.(head), fn result ->
      Comp.bind(fx_map(tail, f), fn rest ->
        Comp.pure([result | rest])
      end)
    end)
  end

  @doc """
  Reduce a list with an effectful function.

  ## Example

      FxList.fx_reduce([1, 2, 3], 0, fn x, acc ->
        comp do
          _ <- Writer.tell("processing \#{x}")
          return(acc + x)
        end
      end)
      # => computation returning 6
  """
  @spec fx_reduce(list(), term(), (term(), term() -> Types.computation())) :: Types.computation()
  def fx_reduce([], acc, _f), do: Comp.pure(acc)

  def fx_reduce([head | tail], acc, f) do
    Comp.bind(f.(head, acc), fn new_acc ->
      fx_reduce(tail, new_acc, f)
    end)
  end

  @doc """
  Execute an effectful function for each element, discarding results.

  Returns a computation that produces `:ok`.

  Useful for benchmarking - run N iterations inside a single computation.

  ## Example

      FxList.fx_each(1..1000, fn i ->
        comp do
          n <- State.get()
          _ <- State.put(n + 1)
          return(:ok)
        end
      end)
      # => computation returning :ok
  """
  @spec fx_each(Enumerable.t(), (term() -> Types.computation())) :: Types.computation()
  def fx_each(enumerable, f) do
    enumerable
    |> Enum.to_list()
    |> do_fx_each(f)
  end

  defp do_fx_each([], _f), do: Comp.pure(:ok)

  defp do_fx_each([head | tail], f) do
    Comp.bind(f.(head), fn _result ->
      do_fx_each(tail, f)
    end)
  end

  @doc """
  Filter a list with an effectful predicate.

  ## Example

      FxList.fx_filter([1, 2, 3, 4], fn x ->
        comp do
          threshold <- Reader.ask()
          return(x > threshold)
        end
      end)
      # With threshold=2 => computation returning [3, 4]
  """
  @spec fx_filter(list(), (term() -> Types.computation())) :: Types.computation()
  def fx_filter([], _pred), do: Comp.pure([])

  def fx_filter([head | tail], pred) do
    Comp.bind(pred.(head), fn keep? ->
      Comp.bind(fx_filter(tail, pred), fn rest ->
        if keep? do
          Comp.pure([head | rest])
        else
          Comp.pure(rest)
        end
      end)
    end)
  end
end
