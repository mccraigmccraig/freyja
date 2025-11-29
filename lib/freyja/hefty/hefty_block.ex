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

  ## Else Clause

  You can add an else clause for pattern match failure handling:

      hefty do
        {:ok, a} <- get_a()
        {:ok, b} <- get_b(a)
        return(a + b)
      else
        {:error, reason} -> return({:failed, reason})
        other -> return({:unhandled, other})
      end

  When a pattern in `<-` or `=` fails to match, the else clause handles it.

  ## Catch Clause

  You can add a catch clause for error handling:

      hefty do
        x <- computation()
        return(x)
      catch
        :specific_error -> return(:handled)
        other -> return({:error, other})
      end

  ## Combined Else and Catch

  Both clauses can be used together. The `else` must come before `catch`:

      hefty do
        {:ok, a} <- might_fail_match()
        _ <- might_throw_error(a)
        return(a)
      else
        {:error, reason} -> return({:match_failed, reason})
      catch
        :some_error -> return(:caught_throw)
      end

  Semantic ordering is fixed: `catch(else(comp, else_handler), catch_handler)`.
  This means:
  - `else` handles pattern match failures from the main computation
  - `catch` handles throws from both the main computation AND the else handler

  ## See Also

  - `Freyja.Freer.FreerBlock` - For first-order (Freer) computations
  - `Freyja.Hefty.Sig.IHeftySendable` - Protocol for auto-lifting
  - `Freyja.Hefty.bind/2` - Monadic bind with auto-lifting
  - `Freyja.Effects.Else` - The Else effect for pattern match failures
  - `Freyja.Effects.Catch` - The Catch effect for exception handling
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
  defmacro defhefty(call_ast, clauses) do
    Freyja.Hefty.HeftyBlock.Impl.defhefty(__CALLER__, call_ast, clauses)
  end

  @doc """
  Define a private function whose body is a `hefty` block.

  Same as `defhefty` but creates a private function (defp).
  """
  defmacro defheftyp(call_ast, clauses) do
    Freyja.Hefty.HeftyBlock.Impl.defheftyp(__CALLER__, call_ast, clauses)
  end

  @doc """
  Do-notation for Hefty computations.

  Rewrites a do-block with `<-` bindings into `Hefty.bind` calls.
  Supports optional `else` and `catch` clauses.

  See the module documentation for full details and examples.
  """
  defmacro hefty(clauses) do
    Freyja.Hefty.HeftyBlock.Impl.hefty(__CALLER__, clauses)
  end

  defmodule Impl do
    @moduledoc """
    Implementation details for hefty macros.

    Expands hefty blocks into Hefty.bind calls with automatic return import.
    """

    def defhefty(caller, call_ast, clauses) do
      validate_clause_ordering!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      else_block = Keyword.get(clauses, :else)
      catch_block = Keyword.get(clauses, :catch)

      quote do
        def unquote(call_ast) do
          Freyja.Hefty.HeftyBlock.hefty(
            unquote(build_hefty_clauses(do_block, else_block, catch_block))
          )
        end
      end
    end

    def defheftyp(caller, call_ast, clauses) do
      validate_clause_ordering!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      else_block = Keyword.get(clauses, :else)
      catch_block = Keyword.get(clauses, :catch)

      quote do
        defp unquote(call_ast) do
          Freyja.Hefty.HeftyBlock.hefty(
            unquote(build_hefty_clauses(do_block, else_block, catch_block))
          )
        end
      end
    end

    defp build_hefty_clauses(do_block, nil, nil) do
      [do: do_block]
    end

    defp build_hefty_clauses(do_block, else_block, nil) do
      [do: do_block, else: else_block]
    end

    defp build_hefty_clauses(do_block, nil, catch_block) do
      [do: do_block, catch: catch_block]
    end

    defp build_hefty_clauses(do_block, else_block, catch_block) do
      [do: do_block, else: else_block, catch: catch_block]
    end

    def hefty(caller, clauses) do
      validate_clause_ordering!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      else_block = Keyword.get(clauses, :else)
      catch_block = Keyword.get(clauses, :catch)

      # Rewrite the do block, generating multi-clause continuations if else is present
      rewritten_do = rewrite_block(do_block, else_block != nil)

      # Wrap with else if present
      with_else =
        if else_block do
          else_handler_fn = build_else_handler_fn(else_block)

          quote do
            Freyja.Effects.Else.else_hefty(
              unquote(rewritten_do),
              unquote(else_handler_fn)
            )
          end
        else
          rewritten_do
        end

      # Wrap with catch if present (outermost)
      with_catch =
        if catch_block do
          catch_handler_fn = build_catch_handler_fn(catch_block)

          quote do
            Freyja.Effects.Catch.catch_hefty(
              unquote(with_else),
              unquote(catch_handler_fn)
            )
          end
        else
          with_else
        end

      quote do
        # Import Hefty.return as return for convenience
        import Freyja.Hefty, only: [return: 1]
        unquote(with_catch)
      end
    end

    # Validate that else comes before catch in the clause list
    defp validate_clause_ordering!(caller, clauses) do
      keys = Keyword.keys(clauses)
      catch_index = Enum.find_index(keys, &(&1 == :catch))
      else_index = Enum.find_index(keys, &(&1 == :else))

      if catch_index && else_index && catch_index < else_index do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "in hefty block, `else` must come before `catch` " <>
              "(else handles pattern match failures, catch handles thrown errors and wraps else)"
      end
    end

    # Rewrite the entire block
    # has_else: whether to generate multi-clause continuations for complex patterns
    defp rewrite_block(block, has_else)

    defp rewrite_block({:__block__, _, exprs}, has_else), do: rewrite_exprs(exprs, has_else)
    defp rewrite_block(expr, has_else), do: rewrite_exprs([expr], has_else)

    # Single expression - just return it
    defp rewrite_exprs([last], _has_else) do
      last
    end

    # Pure assignment (=) - preserve as regular assignment, then continue
    # If has_else and pattern is complex, wrap in case with bind_match_failed fallback
    defp rewrite_exprs([{:=, meta, [lhs, rhs]} | rest], has_else) do
      rest_rewritten = rewrite_exprs(rest, has_else)

      if has_else and complex_pattern?(lhs) do
        # Wrap in case with fallback
        quote do
          case unquote(rhs) do
            unquote(lhs) ->
              unquote(rest_rewritten)

            __freyja_nomatch__ ->
              Freyja.Effects.Lift.lift(Freyja.Effects.Else.bind_match_failed(__freyja_nomatch__))
          end
        end
      else
        # Simple pattern or no else - regular assignment
        quote do
          unquote({:=, meta, [lhs, rhs]})
          unquote(rest_rewritten)
        end
      end
    end

    # Effect binding (<-) - rewrite to Hefty.bind
    # If has_else and pattern is complex, generate multi-clause continuation
    defp rewrite_exprs([{:<-, _meta, [lhs, rhs]} | rest], has_else) do
      rest_rewritten = rewrite_exprs(rest, has_else)

      if has_else and complex_pattern?(lhs) do
        # Generate multi-clause continuation
        binder_with_else(lhs, rhs, rest_rewritten)
      else
        # Simple pattern or no else - regular bind
        binder(lhs, rhs, rest_rewritten)
      end
    end

    # Generate simple Hefty.bind call
    defp binder(lhs, rhs, body) do
      quote do
        unquote(rhs)
        |> Freyja.Hefty.bind(fn unquote(lhs) -> unquote(body) end)
      end
    end

    # Generate Hefty.bind with multi-clause continuation for else support
    defp binder_with_else(lhs, rhs, body) do
      quote do
        unquote(rhs)
        |> Freyja.Hefty.bind(fn
          unquote(lhs) ->
            unquote(body)

          __freyja_nomatch__ ->
            Freyja.Effects.Lift.lift(Freyja.Effects.Else.bind_match_failed(__freyja_nomatch__))
        end)
      end
    end

    # Check if a pattern is "complex" (might fail to match)
    # Simple patterns: variables, underscore
    # Complex patterns: tuples, lists, maps, structs, literals, pins
    defp complex_pattern?({name, _meta, context})
         when is_atom(name) and is_atom(context) and name != :^ do
      # Simple variable (including underscore variants like _foo)
      false
    end

    defp complex_pattern?({:_, _meta, _context}) do
      # Underscore
      false
    end

    defp complex_pattern?(_) do
      # Everything else: tuples, lists, maps, structs, literals, pins, etc.
      true
    end

    # Build the else handler function from else block clauses
    defp build_else_handler_fn(else_block) do
      clauses = extract_clauses(else_block)

      # Rewrite each clause body, preserving the pattern structure
      rewritten_clauses =
        Enum.map(clauses, fn {:->, meta, [patterns, body]} ->
          # Else clause bodies are hefty blocks too, but shouldn't have else
          # (nested else would be confusing)
          rewritten_body = rewrite_block(body, false)
          {:->, meta, [patterns, rewritten_body]}
        end)

      # Check if there's a catch-all clause
      has_catch_all = has_catch_all_clause?(clauses)

      # Add a default rethrow clause if user didn't provide catch-all
      final_clauses =
        if has_catch_all do
          rewritten_clauses
        else
          rewritten_clauses ++
            [
              {:->, [],
               [
                 [quote(do: __freyja_unhandled_match__)],
                 quote(
                   do:
                     Freyja.Effects.Lift.lift(
                       Freyja.Effects.Throw.throw_error(
                         {:bind_match_failed, __freyja_unhandled_match__}
                       )
                     )
                 )
               ]}
            ]
        end

      # Build the function: fn val -> case val do ... end end
      quote do
        fn __freyja_else_value__ ->
          import Freyja.Hefty, only: [return: 1]

          case __freyja_else_value__ do
            unquote(final_clauses)
          end
        end
      end
    end

    # Build the error handler function from catch block clauses
    defp build_catch_handler_fn(catch_block) do
      clauses = extract_clauses(catch_block)

      # Rewrite each clause body, preserving the pattern structure
      rewritten_clauses =
        Enum.map(clauses, fn {:->, meta, [patterns, body]} ->
          rewritten_body = rewrite_block(body, false)
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

    # Extract clauses from a block
    # Handles both single clause and multiple clauses
    defp extract_clauses({:->, _, _} = single_clause) do
      [single_clause]
    end

    defp extract_clauses({:__block__, _, clauses}) do
      clauses
    end

    defp extract_clauses(clauses) when is_list(clauses) do
      clauses
    end

    defp extract_clauses(nil) do
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
