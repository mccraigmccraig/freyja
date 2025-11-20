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

    defcon foo(a), [Reader, Writer] do
      b = 10
      c <- get()
      put(a + b)
      return(a + b + c)
    end

  Note: For exception handling with `catch` clauses, use `defhefty` instead,
  as catch is a higher-order effect that belongs in Hefty.
  """
  defmacro defcon(call_ast, do: body),
    do: Freyja.Con.Impl.defcon(call_ast, [], body)

  defmacro defcon(call_ast, mods_ast, do: body),
    do: Freyja.Con.Impl.defcon(call_ast, mods_ast, body)

  defmacro defconp(call_ast, do: body),
    do: Freyja.Con.Impl.defconp(call_ast, [], body)

  defmacro defconp(call_ast, mods_ast, do: body),
    do: Freyja.Con.Impl.defconp(call_ast, mods_ast, body)

  @doc """
  `con` - profitable cheating - and Spanish/Italian `with`

  https://okmij.org/ftp/Computation/free-monad.html#cheating

  macro sugar which rewrites a with-like statement into
  Freer.bind steps - similar to Haskell `do` notation

  con [Reader, Writer] do
    a <- get()
    b = 10
    put(a + 5)
    return(a + b)
  end

  Note: For exception handling with `catch` clauses, use `hefty` instead,
  as catch is a higher-order effect. See `Freyja.Hefty.HeftyBlock.hefty/1`.
  """
  defmacro con(do: do_block), do: Freyja.Con.Impl.con([], do_block)

  defmacro con(mod_or_mods, do: do_block), do: Freyja.Con.Impl.con(mod_or_mods, do_block)

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

    def con(mod_or_mods, do_block) do
      imports = expand_imports(mod_or_mods)

      quote do
        unquote_splicing(imports)
        unquote(rewrite_block(do_block))
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

    def binder(lhs, rhs, body) do
      quote do
        unquote(rhs)
        |> Freyja.Freer.bind(fn unquote(lhs) -> unquote(body) end)
      end
    end
  end
end
