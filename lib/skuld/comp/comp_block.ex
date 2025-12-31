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

  Function definitions also support catch:

      defcomp safe_get() do
        x <- State.get()
        _ <- if x < 0, do: Throw.throw(:negative), else: Comp.pure(:ok)
        return(x)
      catch
        :negative -> return(0)
      end
  """

  @doc """
  Define a public function whose body is a `comp` block.

  Supports optional `catch` clause.

  ## Example

      defcomp fetch_and_increment() do
        x <- State.get()
        _ <- State.put(x + 1)
        return(x)
      end

      defcomp safe_fetch() do
        x <- dangerous_op()
        return(x)
      catch
        :error -> return(:default)
      end
  """
  defmacro defcomp(call_ast, clauses) do
    Skuld.Comp.CompBlock.Impl.defcomp(__CALLER__, call_ast, clauses)
  end

  @doc """
  Define a private function whose body is a `comp` block.

  Supports optional `catch` clause.

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

  Supports optional `catch` clause for error handling.

  ## Example

      comp do
        x <- State.get()
        y = x * 2
        _ <- State.put(y)
        return(y)
      end

  With catch clause:

      comp do
        x <- risky_operation()
        return(x)
      catch
        :error -> return(:default)
        {:custom, reason} -> return({:failed, reason})
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
      catch_block = Keyword.get(clauses, :catch)

      quote do
        def unquote(call_ast) do
          Skuld.Comp.CompBlock.comp(unquote(build_clauses(do_block, catch_block)))
        end
      end
    end

    def defcompp(caller, call_ast, clauses) do
      validate_clauses!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      catch_block = Keyword.get(clauses, :catch)

      quote do
        defp unquote(call_ast) do
          Skuld.Comp.CompBlock.comp(unquote(build_clauses(do_block, catch_block)))
        end
      end
    end

    defp build_clauses(do_block, nil), do: [do: do_block]
    defp build_clauses(do_block, catch_block), do: [do: do_block, catch: catch_block]

    def comp(caller, clauses) do
      validate_clauses!(caller, clauses)

      do_block = Keyword.fetch!(clauses, :do)
      catch_block = Keyword.get(clauses, :catch)

      # Rewrite the do block
      rewritten_do = rewrite_block(do_block)

      # Wrap with catch if present
      with_catch =
        if catch_block do
          wrap_with_catch(rewritten_do, catch_block)
        else
          rewritten_do
        end

      quote do
        import Skuld.Comp.BaseOps
        unquote(with_catch)
      end
    end

    # Validate that only supported clauses are present
    defp validate_clauses!(caller, clauses) do
      keys = Keyword.keys(clauses)
      invalid = keys -- [:do, :catch]

      if invalid != [] do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "invalid clauses in comp block: #{inspect(invalid)}. Only :do and :catch are supported."
      end

      unless Keyword.has_key?(clauses, :do) do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "comp block requires a :do clause"
      end
    end

    # Wrap the body computation in Throw.catch_error
    defp wrap_with_catch(body, catch_block) do
      catch_handler_fn = build_catch_handler_fn(catch_block)

      quote do
        Skuld.Effects.Throw.catch_error(
          unquote(body),
          unquote(catch_handler_fn)
        )
      end
    end

    # Build the error handler function from catch block clauses
    defp build_catch_handler_fn(catch_block) do
      clauses = extract_clauses(catch_block)

      # Rewrite each clause body (they're comp blocks too)
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

    # Rewrite block expressions
    defp rewrite_block({:__block__, _, exprs}), do: rewrite_exprs(exprs)
    defp rewrite_block(expr), do: rewrite_exprs([expr])

    defp rewrite_exprs([last]) do
      last
    end

    defp rewrite_exprs([{:=, meta, [lhs, rhs]} | rest]) do
      # Pure variable binding - preserve as regular assignment
      quote do
        unquote({:=, meta, [lhs, rhs]})
        unquote(rewrite_exprs(rest))
      end
    end

    defp rewrite_exprs([{:<-, _meta, [lhs, rhs]} | rest]) do
      binder(lhs, rhs, rewrite_exprs(rest))
    end

    defp rewrite_exprs([expr | rest]) do
      # Non-binding expression (e.g., side-effect or ignored computation)
      # Sequence it with then_do
      quote do
        Skuld.Comp.then_do(unquote(expr), unquote(rewrite_exprs(rest)))
      end
    end

    defp binder(lhs, rhs, body) do
      quote do
        Skuld.Comp.bind(unquote(rhs), fn unquote(lhs) -> unquote(body) end)
      end
    end
  end
end
