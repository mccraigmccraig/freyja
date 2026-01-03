defmodule Skuld.Effects.Yield do
  @moduledoc """
  Yield effect - coroutine-style suspension and resumption.

  Uses `%Skuld.Comp.Suspend{}` struct as the suspension result, which
  bypasses leave_scope in Run.

  ## Architecture

  - `yield(value)` suspends computation, returning `%Suspend{value, resume}`
  - The resume function captures the env, so caller just provides input
  - Run recognizes `%Suspend{}` and bypasses leave_scope
  - When resumed, the result goes through the leave_scope chain
  """

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Types

  @sig __MODULE__

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(YieldOp, [:value])

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Yield a value and suspend, waiting for input to resume"
  @spec yield(term()) :: Types.computation()
  def yield(value) do
    Comp.effect(@sig, %YieldOp{value: value})
  end

  @doc "Yield without a value"
  @spec yield() :: Types.computation()
  def yield do
    yield(nil)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped Yield handler for a computation.

  Installs the Yield handler for the duration of `comp`. The handler is
  restored/removed when `comp` completes or suspends.

  The argument order is pipe-friendly.

  ## Example

      # Wrap a computation with Yield handling
      comp_with_yield =
        comp do
          input <- Yield.yield(:question)
          return({:got, input})
        end
        |> Yield.with_handler()

      # Compose with other handlers
      my_comp
      |> Yield.with_handler()
      |> State.with_handler(0)
      |> Comp.run(Env.new())
  """
  @spec with_handler(Types.computation()) :: Types.computation()
  def with_handler(comp) do
    Comp.with_handler(comp, @sig, &__MODULE__.handle/3)
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @doc """
  Handler: returns Suspend struct with resume that captures env
  and invokes leave_scope when the resumed computation completes.
  """
  @impl Skuld.Comp.IHandler
  def handle(%YieldOp{value: value}, env, k) do
    captured_resume = fn input ->
      {result, final_env} = k.(input, env)

      # If the result is another Suspend, don't invoke leave_scope yet
      # (it will be invoked when that suspend is eventually resolved)
      case result do
        %Comp.Suspend{} ->
          {result, final_env}

        _ ->
          # Invoke leave_scope chain on completion
          final_env.leave_scope.(result, final_env)
      end
    end

    {%Comp.Suspend{value: value, resume: captured_resume}, env}
  end

  #############################################################################
  ## Runner Utilities
  #############################################################################

  @doc """
  Run a computation with a driver function that handles yields.

  The driver receives yielded values and returns `{:continue, input}` or `{:stop, reason}`.

  The computation should already have handlers installed via `with_handler`.
  """
  @spec run_with_driver(
          Types.computation(),
          (term() -> {:continue, term()} | {:stop, term()})
        ) ::
          {:done, term(), Types.env()}
          | {:stopped, term(), Types.env()}
          | {:thrown, term(), Types.env()}
  def run_with_driver(comp, driver) do
    case Comp.run(comp) do
      {%Comp.Suspend{value: yielded, resume: resume}, suspended_env} ->
        case driver.(yielded) do
          {:continue, input} ->
            # Resume returns {result, env} with leave_scope already applied
            {result, new_env} = resume.(input)
            continue_with_driver(result, new_env, driver)

          {:stop, reason} ->
            {:stopped, reason, suspended_env}
        end

      {%Comp.Throw{error: error}, err_env} ->
        {:thrown, error, err_env}

      {value, final_env} ->
        {:done, value, final_env}
    end
  end

  # Continue processing after a resume
  defp continue_with_driver(%Comp.Suspend{value: yielded, resume: resume}, env, driver) do
    case driver.(yielded) do
      {:continue, input} ->
        {result, new_env} = resume.(input)
        continue_with_driver(result, new_env, driver)

      {:stop, reason} ->
        {:stopped, reason, env}
    end
  end

  defp continue_with_driver(%Comp.Throw{error: error}, env, _driver) do
    {:thrown, error, env}
  end

  defp continue_with_driver(value, env, _driver) do
    {:done, value, env}
  end

  @doc """
  Collect all yielded values until completion.

  Resumes with the provided input value (default: nil) each time.

  The computation should already have handlers installed via `with_handler`.
  """
  @spec collect(Types.computation(), term()) ::
          {:done, term(), [term()], Types.env()}
          | {:thrown, term(), [term()], Types.env()}
  def collect(comp, resume_input \\ nil) do
    case Comp.run(comp) do
      {%Comp.Suspend{} = suspend, suspended_env} ->
        do_collect(suspend, suspended_env, [], resume_input)

      {%Comp.Throw{error: error}, err_env} ->
        {:thrown, error, [], err_env}

      {value, final_env} ->
        {:done, value, [], final_env}
    end
  end

  defp do_collect(%Comp.Suspend{value: yielded, resume: resume}, _env, acc, input) do
    {result, new_env} = resume.(input)

    case result do
      %Comp.Suspend{} = suspend ->
        do_collect(suspend, new_env, [yielded | acc], input)

      %Comp.Throw{error: error} ->
        {:thrown, error, Enum.reverse([yielded | acc]), new_env}

      value ->
        {:done, value, Enum.reverse([yielded | acc]), new_env}
    end
  end

  @doc """
  Feed a list of inputs to a computation, collecting yields.

  Each yield consumes one input. If inputs run out, stops with remaining computation.

  The computation should already have handlers installed via `with_handler`.
  """
  @spec feed(Types.computation(), [term()]) ::
          {:done, term(), [term()], Types.env()}
          | {:suspended, term(), (term() -> {Types.result(), Types.env()}), [term()], Types.env()}
          | {:thrown, term(), [term()], Types.env()}
  def feed(comp, inputs) do
    case Comp.run(comp) do
      {%Comp.Suspend{} = suspend, suspended_env} ->
        do_feed(suspend, suspended_env, [], inputs)

      {%Comp.Throw{error: error}, err_env} ->
        {:thrown, error, [], err_env}

      {value, final_env} ->
        {:done, value, [], final_env}
    end
  end

  defp do_feed(%Comp.Suspend{value: yielded, resume: resume}, env, yielded_acc, []) do
    {:suspended, yielded, resume, Enum.reverse(yielded_acc), env}
  end

  defp do_feed(%Comp.Suspend{value: yielded, resume: resume}, _env, yielded_acc, [input | rest]) do
    {result, new_env} = resume.(input)

    case result do
      %Comp.Suspend{} = suspend ->
        do_feed(suspend, new_env, [yielded | yielded_acc], rest)

      %Comp.Throw{error: error} ->
        {:thrown, error, Enum.reverse([yielded | yielded_acc]), new_env}

      value ->
        {:done, value, Enum.reverse([yielded | yielded_acc]), new_env}
    end
  end
end
