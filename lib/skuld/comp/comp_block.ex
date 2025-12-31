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
  """

  @doc """
  Define a public function whose body is a `comp` block.

  ## Example

      defcomp fetch_and_increment() do
        x <- State.get()
        _ <- State.put(x + 1)
        return(x)
      end
  """
  defmacro defcomp(call_ast, do: body) do
    Skuld.Comp.CompBlock.Impl.defcomp(call_ast, body)
  end

  @doc """
  Define a private function whose body is a `comp` block.

  ## Example

      defcompp internal_helper() do
        x <- Reader.ask()
        return(x.config)
      end
  """
  defmacro defcompp(call_ast, do: body) do
    Skuld.Comp.CompBlock.Impl.defcompp(call_ast, body)
  end

  @doc """
  Create a computation using do-notation style syntax.

  Transforms arrow bindings (`<-`) into `Skuld.Comp.bind` chains.
  Regular assignments (`=`) are preserved as-is.

  ## Example

      comp do
        x <- State.get()
        y = x * 2
        _ <- State.put(y)
        return(y)
      end

  Is transformed into:

      State.get()
      |> Skuld.Comp.bind(fn x ->
        y = x * 2
        State.put(y)
        |> Skuld.Comp.bind(fn _ ->
          Skuld.Comp.pure(y)
        end)
      end)
  """
  defmacro comp(do: do_block) do
    Skuld.Comp.CompBlock.Impl.comp(do_block)
  end

  defmodule Impl do
    @moduledoc false

    def defcomp(call_ast, body) do
      quote do
        def unquote(call_ast) do
          Skuld.Comp.CompBlock.comp do
            unquote(body)
          end
        end
      end
    end

    def defcompp(call_ast, body) do
      quote do
        defp unquote(call_ast) do
          Skuld.Comp.CompBlock.comp do
            unquote(body)
          end
        end
      end
    end

    def comp(do_block) do
      quote do
        import Skuld.Comp.BaseOps
        unquote(rewrite_block(do_block))
      end
    end

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
