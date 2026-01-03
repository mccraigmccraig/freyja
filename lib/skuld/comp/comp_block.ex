defmodule Skuld.Comp.CompBlock do
  @moduledoc """
  The `comp` macro for monadic do-notation style effect composition.

  Provides `comp`, `defcomp`, and `defcompp` macros that transform
  arrow notation (`<-`) into `Skuld.Comp.bind` chains.

  ## Usage

      import Skuld.Comp.CompBlock

      comp do
        x <- State.get()
        y = x + 1
        _ <- State.put(y)
        return(y)
      end

  ## Syntax

  - `x <- effect()` - bind the result of an effectful computation
  - `x = expr` - pure variable binding (unchanged)
  - `return(value)` - lift a pure value (from `Skuld.Comp.BaseOps`)
  - Last expression is the final computation

  ## Else Clause

  You can add an else clause to handle pattern match failures in `<-` bindings:

      comp do
        {:ok, x} <- maybe_returns_error()
        return(x)
      else
        {:error, reason} -> return({:failed, reason})
        other -> return({:unexpected, other})
      end

  When a pattern in `<-` fails to match, the else clause handles the unmatched value.

  ## Catch Clause

  You can add a catch clause for error handling:

      comp do
        x <- State.get()
        _ <- if x < 0, do: Throw.throw(:negative), else: Comp.pure(:ok)
        return(x * 2)
      catch
        :negative -> return(0)
        other -> return({:error, other})
      end

  When an error is thrown, it's matched against the catch patterns.
  If no pattern matches and there's no catch-all, the error is re-thrown.

  ## Combined Else and Catch

  Both clauses can be used together. The `else` must come before `catch`:

      comp do
        {:ok, x} <- might_fail_match()
        _ <- might_throw_error(x)
        return(x)
      else
        {:error, reason} -> return({:match_failed, reason})
      catch
        :some_error -> return(:caught_throw)
      end

  Semantic ordering: `catch(else(body))`. This means:
  - `else` handles pattern match failures from the main computation
  - `catch` handles throws from both the main computation AND the else handler

  ## Installing Handlers

  Use the pipe operator with `Module.with_handler/2` to install scoped handlers:

      comp do
        x <- State.get()
        y <- Reader.ask()
        return(x + y)
      end
      |> State.with_handler(0)
      |> Reader.with_handler(:config)

  Handlers are applied in order (first in pipe = innermost).

  ## Function Definitions

      defcomp increment() do
        x <- State.get()
        _ <- State.put(x + 1)
        return(x + 1)
      end

      defcompp private_helper() do
        ctx <- Reader.ask()
        return(ctx.value)
      end

  Function definitions also support else and catch:

      defcomp safe_get() do
        {:ok, x} <- fetch_value()
        return(x)
      else
        {:error, _} -> return(:default)
      catch
        :serious_error -> return(:fallback)
      end
  """

  @doc """
  Define a public function whose body is a `comp` block.

  Supports optional `else` and `catch` clauses.

  ## Example

      defcomp fetch_and_increment() do
        x <- State.get()
        _ <- State.put(x + 1)
        return(x)
      end

      defcomp safe_fetch() do
        {:ok, x} <- dangerous_op()
        return(x)
      else
        {:error, _} -> return(:default)
      catch
        :error -> return(:fallback)
      end
  """
  defmacro defcomp(call_ast, clauses) do
    Skuld.Comp.CompBlock.Impl.defcomp(__CALLER__, call_ast, clauses)
  end

  @doc """
  Define a private function whose body is a `comp` block.

  Supports optional `else` and `catch` clauses.

  ## Example

      defcompp internal_helper() do
        x <- Reader.ask()
        return(x.config)
      end
  """
  defmacro defcompp(call_ast, clauses) do
    Skuld.Comp.CompBlock.Impl.defcompp(__CALLER__, call_ast, clauses)
  end

  @doc """
  Create a computation using do-notation style syntax.

  Transforms arrow bindings (`<-`) into `Skuld.Comp.bind` chains.
  Regular assignments (`=`) are preserved as-is.

  Supports optional `else` and `catch` clauses.

  ## Example

      comp do
        x <- State.get()
        y = x * 2
        _ <- State.put(y)
        return(y)
      end

  With else and catch clauses:

      comp do
        {:ok, x} <- risky_operation()
        return(x)
      else
        {:error, reason} -> return({:failed, reason})
      catch
        :error -> return(:default)
      end
  """
  defmacro comp(clauses) do
    Skuld.Comp.CompBlock.Impl.comp(__CALLER__, clauses)
  end

  defmodule Impl do
    @moduledoc false

    def defcomp(caller, call_ast, clauses) do
      validate_clauses!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      else_block = Keyword.get(clauses, :else)
      catch_block = Keyword.get(clauses, :catch)

      quote do
        def unquote(call_ast) do
          Skuld.Comp.CompBlock.comp(unquote(build_clauses(do_block, else_block, catch_block)))
        end
      end
    end

    def defcompp(caller, call_ast, clauses) do
      validate_clauses!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      else_block = Keyword.get(clauses, :else)
      catch_block = Keyword.get(clauses, :catch)

      quote do
        defp unquote(call_ast) do
          Skuld.Comp.CompBlock.comp(unquote(build_clauses(do_block, else_block, catch_block)))
        end
      end
    end

    defp build_clauses(do_block, else_block, catch_block) do
      # Build clauses in correct order: do, else, catch
      # Using list concatenation to preserve order (Keyword.put prepends)
      [{:do, do_block}]
      |> maybe_append_clause(:else, else_block)
      |> maybe_append_clause(:catch, catch_block)
    end

    defp maybe_append_clause(clauses, _key, nil), do: clauses
    defp maybe_append_clause(clauses, key, value), do: clauses ++ [{key, value}]

    def comp(caller, clauses) do
      validate_clauses!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      else_block = Keyword.get(clauses, :else)
      catch_block = Keyword.get(clauses, :catch)

      # Rewrite the do block, generating multi-clause continuations if else is present
      has_else = else_block != nil
      rewritten_do = rewrite_block(do_block, has_else)

      # Wrap with else if present (innermost)
      with_else =
        if else_block do
          wrap_with_else(rewritten_do, else_block)
        else
          rewritten_do
        end

      # Wrap with catch if present (outermost)
      result =
        if catch_block do
          wrap_with_catch(with_else, catch_block)
        else
          with_else
        end

      quote do
        import Skuld.Comp.BaseOps
        unquote(result)
      end
    end

    # Validate that only supported clauses are present and in correct order
    defp validate_clauses!(caller, clauses) do
      keys = Keyword.keys(clauses)
      invalid = keys -- [:do, :else, :catch]

      if invalid != [] do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "invalid clauses in comp block: #{inspect(invalid)}. " <>
              "Only :do, :else, and :catch are supported."
      end

      unless Keyword.has_key?(clauses, :do) do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "comp block requires a :do clause"
      end

      # Validate ordering: else must come before catch
      catch_index = Enum.find_index(keys, &(&1 == :catch))
      else_index = Enum.find_index(keys, &(&1 == :else))

      if catch_index && else_index && catch_index < else_index do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "in comp block, `else` must come before `catch` " <>
              "(else handles pattern match failures, catch handles thrown errors and wraps else)"
      end
    end

    # Wrap the body computation in Throw.catch_error for else handling
    defp wrap_with_else(body, else_block) do
      else_handler_fn = build_else_handler_fn(else_block)

      quote do
        Skuld.Effects.Throw.catch_error(
          unquote(body),
          unquote(else_handler_fn)
        )
      end
    end

    # Wrap the body computation in Throw.catch_error for catch handling
    defp wrap_with_catch(body, catch_block) do
      catch_handler_fn = build_catch_handler_fn(catch_block)

      quote do
        Skuld.Effects.Throw.catch_error(
          unquote(body),
          unquote(catch_handler_fn)
        )
      end
    end

    # Build the else handler function
    # Catches MatchFailed, re-throws other errors
    defp build_else_handler_fn(else_block) do
      clauses = extract_clauses(else_block)

      # Rewrite each clause body (they're comp blocks too, but no else support nested)
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
                 [quote(do: __skuld_unhandled_match__)],
                 quote(
                   do:
                     Skuld.Effects.Throw.throw(%Skuld.Comp.MatchFailed{
                       value: __skuld_unhandled_match__
                     })
                 )
               ]}
            ]
        end

      # Build the function that catches MatchFailed, re-throws others
      quote do
        fn
          %Skuld.Comp.MatchFailed{value: __skuld_match_value__} ->
            import Skuld.Comp.BaseOps

            case __skuld_match_value__ do
              unquote(final_clauses)
            end

          __skuld_other_error__ ->
            Skuld.Effects.Throw.throw(__skuld_other_error__)
        end
      end
    end

    # Build the error handler function from catch block clauses
    defp build_catch_handler_fn(catch_block) do
      clauses = extract_clauses(catch_block)

      # Rewrite each clause body (they're comp blocks too)
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
                 [quote(do: __skuld_unhandled_error__)],
                 quote(do: Skuld.Effects.Throw.throw(__skuld_unhandled_error__))
               ]}
            ]
        end

      # Build the function: fn err -> case err do ... end end
      quote do
        fn __skuld_error__ ->
          import Skuld.Comp.BaseOps

          case __skuld_error__ do
            unquote(final_clauses)
          end
        end
      end
    end

    # Extract clauses from a block
    defp extract_clauses({:->, _, _} = single_clause), do: [single_clause]
    defp extract_clauses({:__block__, _, clauses}), do: clauses
    defp extract_clauses(clauses) when is_list(clauses), do: clauses
    defp extract_clauses(nil), do: []

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

    # Rewrite block expressions
    # has_else: whether to generate multi-clause continuations for complex patterns
    defp rewrite_block(block, has_else)

    defp rewrite_block({:__block__, _, exprs}, has_else), do: rewrite_exprs(exprs, has_else)
    defp rewrite_block(expr, has_else), do: rewrite_exprs([expr], has_else)

    defp rewrite_exprs([last], _has_else) do
      last
    end

    defp rewrite_exprs([{:=, meta, [lhs, rhs]} | rest], has_else) do
      rest_rewritten = rewrite_exprs(rest, has_else)

      if has_else and complex_pattern?(lhs) do
        # Wrap in case with fallback for match failure
        quote do
          case unquote(rhs) do
            unquote(lhs) ->
              unquote(rest_rewritten)

            __skuld_nomatch__ ->
              Skuld.Effects.Throw.throw(%Skuld.Comp.MatchFailed{value: __skuld_nomatch__})
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

    defp rewrite_exprs([{:<-, _meta, [lhs, rhs]} | rest], has_else) do
      rest_rewritten = rewrite_exprs(rest, has_else)

      if has_else and complex_pattern?(lhs) do
        # Generate multi-clause bind with match failure throw
        binder_with_else(lhs, rhs, rest_rewritten)
      else
        # Simple pattern or no else - regular bind
        binder(lhs, rhs, rest_rewritten)
      end
    end

    defp rewrite_exprs([expr | rest], has_else) do
      # Non-binding expression (e.g., side-effect or ignored computation)
      # Sequence it with then_do
      quote do
        Skuld.Comp.then_do(unquote(expr), unquote(rewrite_exprs(rest, has_else)))
      end
    end

    defp binder(lhs, rhs, body) do
      quote do
        Skuld.Comp.bind(unquote(rhs), fn unquote(lhs) -> unquote(body) end)
      end
    end

    # Generate bind with multi-clause continuation for else support
    defp binder_with_else(lhs, rhs, body) do
      quote do
        Skuld.Comp.bind(unquote(rhs), fn
          unquote(lhs) ->
            unquote(body)

          __skuld_nomatch__ ->
            Skuld.Effects.Throw.throw(%Skuld.Comp.MatchFailed{value: __skuld_nomatch__})
        end)
      end
    end
  end
end
