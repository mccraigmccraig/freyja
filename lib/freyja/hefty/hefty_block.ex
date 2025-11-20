defmodule Freyja.Hefty.HeftyBlock do
  @moduledoc """
  The `hefty` macro for do-notation with Hefty computations.

  Provides `hefty` and `defhefty` macros for writing higher-order effect
  computations with automatic lifting of first-order (Freer) effects.

  ## Overview

  - `hefty do ... end` - Do-notation for Hefty computations
  - `defhefty name(...) do ... end` - Define functions returning Hefty
  - `defheftyp name(...) do ... end` - Define private functions returning Hefty

  ## Comparison with con

  | Feature | con | hefty |
  |---------|-----|-------|
  | Returns | Freer.Impure | Hefty.Impure |
  | Imports | Freyja.Freer.BaseOps | Freyja.Hefty.BaseOps |
  | Bind | Freyja.Freer.bind | Freyja.Hefty.bind |
  | Auto-lift | No | Yes (via IHeftySendable) |
  | Use case | First-order only | Mixed first+higher-order |

  ## Usage

      import Freyja.Hefty.HeftyBlock

      # Simple hefty block
      hefty do
        x <- State.get()           # Freer - auto-lifted!
        y <- Catch.catch_hefty(    # Hefty
          hefty do
            State.put(x * 2)       # Freer - auto-lifted!
            Hefty.pure(x * 2)
          end,
          fn _err -> Hefty.pure(0) end
        )
        Hefty.pure(y)
      end

      # Define function returning Hefty
      defhefty process_items(items) do
        results <- FxMap.fx_map(items, fn item ->
          hefty do
            count <- State.get()
            State.put(count + 1)
            Hefty.pure(item * 2)
          end
        end)
        Hefty.pure(results)
      end

  ## Auto-Lifting

  When you use first-order effects (State, Reader, etc.) in a `hefty` block,
  they are automatically lifted to Hefty via `Freyja.Hefty.Sig.IHeftySendable` protocol.

  This happens in `Hefty.bind/2`'s catch-all clause, which uses the protocol
  to convert Freer computations to Hefty (via Lift).

  No manual `Lift.lift()` calls needed!

  ## Return Values

  Always use `Hefty.pure()` or `Hefty.return()` in hefty blocks:

      hefty do
        x <- computation()
        Hefty.pure(x)  # Correct
      end

      hefty do
        x <- computation()
        Freer.pure(x)  # Will work (auto-lifted) but semantically wrong
      end

  The `hefty` macro automatically imports `Hefty.return/1` as `return/1`.

  ## See Also

  - `Freyja.Hefty.FreerBlock` - For first-order (Freer) computations
  - `Freyja.Hefty.Sig.IHeftySendable` - Protocol for auto-lifting
  - `Freyja.Hefty.bind/2` - Monadic bind with auto-lifting
  """

  @doc """
  Define a function whose body is a `hefty` block.

  The function returns a Hefty computation that must be elaborated before
  interpretation.

  ## Usage

      import Freyja.Hefty.HeftyBlock

      defhefty process(items) do
        results <- FxMap.fx_map(items, &process_item/1)
        Hefty.pure(results)
      end

  ## Returns

  The function returns `Hefty.t()` which must be elaborated using
  `Run.run/4` or `Hefty.Elaborate.elaborate/2`.
  """
  defmacro defhefty(call_ast, do: body) do
    Freyja.Hefty.HeftyBlock.Impl.defhefty(call_ast, body, nil)
  end

  defmacro defhefty(call_ast, do: body, catch: catch_block) do
    Freyja.Hefty.HeftyBlock.Impl.defhefty(call_ast, body, catch_block)
  end

  @doc """
  Define a private function whose body is a `hefty` block.

  Same as `defhefty` but creates a private function (defp).
  """
  defmacro defheftyp(call_ast, do: body) do
    Freyja.Hefty.HeftyBlock.Impl.defheftyp(call_ast, body, nil)
  end

  defmacro defheftyp(call_ast, do: body, catch: catch_block) do
    Freyja.Hefty.HeftyBlock.Impl.defheftyp(call_ast, body, catch_block)
  end

  @doc """
  Do-notation for Hefty computations.

  Rewrites a do-block with `<-` bindings into `Hefty.bind` calls.
  Automatically imports `Hefty.return/1` as `return/1`.

  ## Syntax

      hefty do
        x <- computation1()
        y = plain_value        # Regular assignment
        z <- computation2(y)
        Hefty.pure(x + z)
      end

  ## Catch Clause

  You can add a catch clause for error handling:

      hefty do
        x <- computation()
        return(x)
      catch
        :specific_error -> return(:handled)
        other -> return({:error, other})
      end

  This is syntactic sugar that expands to:

      Catch.catch_hefty(
        hefty do x <- computation(); return(x) end,
        fn err ->
          case err do
            :specific_error -> return(:handled)
            other -> return({:error, other})
          end
        end
      )

  ## Auto-Lifting

  First-order effects (Freer) are automatically lifted to Hefty:

      hefty do
        x <- State.get()       # Freer.Impure - auto-lifted via protocol!
        y <- Catch.catch_hefty(...) # Hefty.Impure - stays as-is
        Hefty.pure(x + y)
      end

  The auto-lifting happens in `Hefty.bind/2`'s catch-all clause via
  `Freyja.Hefty.Sig.IHeftySendable.send_to_hefty/1`.

  ## Examples

      # Simple state computation
      hefty do
        x <- State.get()
        State.put(x + 1)
        y <- State.get()
        Hefty.pure(y)
      end

      # With higher-order effects
      hefty do
        result <- Catch.catch_hefty(
          hefty do
            x <- State.get()
            if x < 0 do
              Error.throw_error("negative")
            else
              Hefty.pure(x * 2)
            end
          end,
          fn _err -> Hefty.pure(0) end
        )
        Hefty.pure(result)
      end

      # Using catch clause syntax
      hefty do
        x <- State.get()
        if x < 0 do
          Error.throw_error("negative")
        else
          Hefty.pure(x * 2)
        end
      catch
        "negative" -> return(0)
        other -> return({:error, other})
      end
  """
  defmacro hefty(do: do_block) do
    Freyja.Hefty.HeftyBlock.Impl.hefty(do_block, nil)
  end

  defmacro hefty(do: do_block, catch: catch_block) do
    Freyja.Hefty.HeftyBlock.Impl.hefty(do_block, catch_block)
  end

  defmodule Impl do
    @moduledoc """
    Implementation details for hefty macros.

    Expands hefty blocks into Hefty.bind calls with automatic return import.
    """

    def defhefty(call_ast, body, nil) do
      quote do
        def unquote(call_ast) do
          Freyja.Hefty.HeftyBlock.hefty do
            unquote(body)
          end
        end
      end
    end

    def defhefty(call_ast, body, catch_block) do
      quote do
        def unquote(call_ast) do
          Freyja.Hefty.HeftyBlock.hefty do
            unquote(body)
          catch
            unquote(catch_block)
          end
        end
      end
    end

    def defheftyp(call_ast, body, nil) do
      quote do
        defp unquote(call_ast) do
          Freyja.Hefty.HeftyBlock.hefty do
            unquote(body)
          end
        end
      end
    end

    def defheftyp(call_ast, body, catch_block) do
      quote do
        defp unquote(call_ast) do
          Freyja.Hefty.HeftyBlock.hefty do
            unquote(body)
          catch
            unquote(catch_block)
          end
        end
      end
    end

    def hefty(do_block, nil) do
      quote do
        # Import Hefty.return as return for convenience
        import Freyja.Hefty, only: [return: 1]
        unquote(rewrite_block(do_block))
      end
    end

    def hefty(do_block, catch_block) do
      try_comp = rewrite_block(do_block)
      handler_fn = build_catch_handler_fn(catch_block)

      quote do
        # Import Hefty.return as return for convenience
        import Freyja.Hefty, only: [return: 1]

        Freyja.Effects.Catch.catch_hefty(
          unquote(try_comp),
          unquote(handler_fn)
        )
      end
    end

    # Rewrite the entire block
    defp rewrite_block({:__block__, _, exprs}), do: rewrite_exprs(exprs)
    defp rewrite_block(expr), do: rewrite_exprs([expr])

    # Single expression - just return it
    defp rewrite_exprs([last]) do
      last
    end

    # Pure assignment (=) - preserve as regular assignment, then continue
    defp rewrite_exprs([{:=, meta, [lhs, rhs]} | rest]) do
      quote do
        unquote({:=, meta, [lhs, rhs]})
        unquote(rewrite_exprs(rest))
      end
    end

    # Effect binding (<-) - rewrite to Hefty.bind
    defp rewrite_exprs([{:<-, _meta, [lhs, rhs]} | rest]) do
      binder(lhs, rhs, rewrite_exprs(rest))
    end

    # Generate Hefty.bind call
    defp binder(lhs, rhs, body) do
      quote do
        unquote(rhs)
        |> Freyja.Hefty.bind(fn unquote(lhs) -> unquote(body) end)
      end
    end

    # Build the error handler function from catch block clauses
    defp build_catch_handler_fn(catch_block) do
      # Extract clauses from the catch block
      clauses = extract_catch_clauses(catch_block)

      # Rewrite each clause body using rewrite_block, preserving the pattern structure
      rewritten_clauses =
        Enum.map(clauses, fn {:->, meta, [patterns, body]} ->
          rewritten_body = rewrite_block(body)
          {:->, meta, [patterns, rewritten_body]}
        end)

      # Check if there's a catch-all clause
      has_catch_all = has_catch_all_clause?(clauses)

      # Add a default re-throw clause if user didn't provide catch-all
      final_clauses =
        if has_catch_all do
          rewritten_clauses
        else
          rewritten_clauses ++
            [
              {:->, [],
               [
                 [quote(do: __freyja_unhandled_error__)],
                 quote(
                   do:
                     Freyja.Effects.Lift.lift(
                       Freyja.Effects.Throw.throw_error(__freyja_unhandled_error__)
                     )
                 )
               ]}
            ]
        end

      # Build the function: fn err -> case err do ... end end
      quote do
        fn __freyja_error__ ->
          import Freyja.Hefty, only: [return: 1]

          case __freyja_error__ do
            unquote(final_clauses)
          end
        end
      end
    end

    # Extract clauses from catch block
    # Handles both single clause and multiple clauses
    defp extract_catch_clauses({:->, _, _} = single_clause) do
      [single_clause]
    end

    defp extract_catch_clauses({:__block__, _, clauses}) do
      clauses
    end

    defp extract_catch_clauses(clauses) when is_list(clauses) do
      clauses
    end

    defp extract_catch_clauses(nil) do
      []
    end

    # Check if there's a catch-all clause (variable pattern or _)
    defp has_catch_all_clause?(clauses) do
      Enum.any?(clauses, fn
        {:->, _, [[{var, _, context}], _body]}
        when is_atom(var) and is_atom(context) and var != :^ ->
          # Variable pattern (but not pinned)
          true

        {:->, _, [[{:_, _, _}], _body]} ->
          # Underscore pattern
          true

        _ ->
          false
      end)
    end
  end
end
