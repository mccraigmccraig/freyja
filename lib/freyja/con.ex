defmodule Freyja.Con do
  @moduledoc """
  The `con` macro for `with`-like effect binding syntax, along
  with `defcon` and `defconp` for defining functions with the
  same syntax
  """

  @doc """
  Define a function whose body is a `Freyja.Con.con` block.

  Usage:
    import Freyja.Con

    defcon foo(a, b), [Reader, Writer] do
      c <- get()
      put(a + b)
      return(a + b + c)
    end

  With else:
    import Freyja.Con

    defcon foo(a), [Error] do
      _ <- Error.throw_fx(:bad)
      return(a)
    else
      :bad -> return(:ok)
    end
  """
  defmacro defcon(call_ast, do: body),
    do: Freyja.Con.Impl.defcon(call_ast, [], body)

  defmacro defcon(call_ast, do: body, catch: else_block),
    do: Freyja.Con.Impl.defcon(call_ast, [], body, else_block)

  defmacro defcon(call_ast, mods_ast, do: body),
    do: Freyja.Con.Impl.defcon(call_ast, mods_ast, body)

  defmacro defcon(call_ast, mods_ast, do: body, catch: else_block),
    do: Freyja.Con.Impl.defcon(call_ast, mods_ast, body, else_block)

  defmacro defconp(call_ast, do: body),
    do: Freyja.Con.Impl.defconp(call_ast, [], body)

  defmacro defconp(call_ast, do: body, catch: else_block),
    do: Freyja.Con.Impl.defconp(call_ast, [], body, else_block)

  defmacro defconp(call_ast, mods_ast, do: body),
    do: Freyja.Con.Impl.defconp(call_ast, mods_ast, body)

  defmacro defconp(call_ast, mods_ast, do: body, catch: else_block),
    do: Freyja.Con.Impl.defconp(call_ast, mods_ast, body, else_block)

  @doc """
  `con` - profitable cheating -and Spanish/Italian `with`

  macro sugar which rewrites a with-like statement into
  Freer.bind steps - similar to Haskell `do` notation

  con [Reader, Writer] do
    a <- get()
    put(a + 5)
    return(a + 10)
  end

  there's also a `catch` clause which translates into an `Error`
  effect `catch_fx` operation

  Freer.con [Error, Writer] do
    _ <- put(:before)
    _ <- throw_fx(:bad)
    _ <- put(:after)
    return(:nope)
  catch
    :bad ->
      _ <- put({:handled, :bad})
      return(:ok)
  end

  """

  defmacro con(do: do_block), do: Freyja.Con.Impl.con([], do_block)

  defmacro con(do: do_block, catch: else_block),
    do: Freyja.Con.Impl.con([], do_block, else_block)

  defmacro con(mod_or_mods, do: do_block), do: Freyja.Con.Impl.con(mod_or_mods, do_block)

  defmacro con(mod_or_mods, do: do_block, catch: else_block),
    do: Freyja.Con.Impl.con(mod_or_mods, do_block, else_block)

  defmodule Impl do
    @moduledoc """
    private implementaion
    """
    def defcon(call_ast, mods_ast, body) do
      mods_list = List.wrap(mods_ast)

      quote do
        def unquote(call_ast) do
          Freyja.Con.con unquote(mods_list) do
            unquote(body)
          end
        end
      end
    end

    def defcon(call_ast, mods_ast, body, else_block) do
      mods_list = List.wrap(mods_ast)

      quote do
        def unquote(call_ast) do
          Freyja.Con.con(unquote(mods_list), do: unquote(body), catch: unquote(else_block))
        end
      end
    end

    @doc """
    Private variant of defcon. Defines a defp with a Freer.con body.
    """
    def defconp(call_ast, mods_ast, body) do
      mods_list = List.wrap(mods_ast)

      quote do
        defp unquote(call_ast) do
          Freyja.Con.con unquote(mods_list) do
            unquote(body)
          end
        end
      end
    end

    def defconp(call_ast, mods_ast, body, catch_block) do
      mods_list = List.wrap(mods_ast)

      quote do
        defp unquote(call_ast) do
          Freyja.Con.con(unquote(mods_list), do: unquote(body), catch: unquote(catch_block))
        end
      end
    end

    def con(mod_or_mods, do_block) do
      imports = expand_imports(mod_or_mods)

      quote do
        unquote_splicing(imports)
        unquote(rewrite_block(do_block))
      end
    end

    def con(mod_or_mods, do_block, catch_block) do
      imports = expand_imports(mod_or_mods)
      body = rewrite_block(do_block)
      handler = build_else_handler_fn(catch_block)

      quote do
        unquote_splicing(imports)
        Freyja.Effects.Error.catch_fx(unquote(body), unquote(handler))
      end
    end

    def expand_imports(mod_or_mods) do
      mods = mod_or_mods |> List.wrap()

      # always include the BaseOps in the imports
      all_mods = [Freyja.Freer.BaseOps | mods] |> Enum.uniq()

      all_mods
      |> Enum.map(fn mod ->
        quote do
          import unquote(mod)
        end
      end)
    end

    def rewrite_block({:__block__, _, exprs}), do: rewrite_exprs(exprs)
    def rewrite_block(expr), do: rewrite_exprs([expr])

    def rewrite_exprs([last]) do
      last
    end

    def rewrite_exprs([{:=, meta, [lhs, rhs]} | rest]) do
      # Pure variable binding - preserve as regular assignment
      quote do
        unquote({:=, meta, [lhs, rhs]})
        unquote(rewrite_exprs(rest))
      end
    end

    def rewrite_exprs([{:<-, _m, [lhs, rhs]} | rest]) do
      binder(lhs, rhs, rewrite_exprs(rest))
    end

    def rewrite_exprs([expr | rest]) do
      binder(quote(do: _), expr, rewrite_exprs(rest))
    end

    def binder(lhs, rhs, body) do
      quote do
        unquote(rhs)
        |> Freyja.Freer.bind(fn unquote(lhs) -> unquote(body) end)
      end
    end

    # Build a multi-clause fn from an catch block with `->` clauses
    def build_else_handler_fn(else_block) do
      clauses =
        case else_block do
          {:__block__, _, exprs} -> exprs
          single_list when is_list(single_list) -> single_list
          single -> [single]
        end

      built_clauses =
        Enum.map(clauses, fn
          {:->, meta, [[pattern], rhs]} ->
            body_ast =
              case rhs do
                {:__block__, _, exprs} -> rewrite_block({:__block__, [], exprs})
                list when is_list(list) -> rewrite_block({:__block__, [], list})
                other -> rewrite_block(other)
              end

            {:->, meta, [[pattern], body_ast]}

          other ->
            raise ArgumentError,
                  "Freer.con catch expects `pattern -> expr` clauses, got: #{inspect(other, pretty: true)}"
        end)

      has_user_default =
        Enum.any?(clauses, fn
          {:->, _m, [[pattern], _rhs]} -> underscore_pattern?(pattern)
          _ -> false
        end)

      final_clauses =
        if has_user_default do
          built_clauses
        else
          default_err = Macro.var(:err, nil)

          default_clause =
            {:->, [],
             [[default_err], quote(do: Freyja.Effects.Error.throw_fx(unquote(default_err)))]}

          built_clauses ++ [default_clause]
        end

      {:fn, [], final_clauses}
    end

    defp underscore_pattern?(ast) do
      case ast do
        {:_, _, _} -> true
        _ -> false
      end
    end
  end
end
