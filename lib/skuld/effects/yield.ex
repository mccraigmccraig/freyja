defmodule Skuld.Effects.Yield do
  @moduledoc """
  Yield effect - coroutine-style suspension and resumption.

  Uses `%Skuld.Suspend{}` struct as the suspension result, which
  bypasses leave_scope in Run.

  ## Architecture

  - `yield(value)` suspends computation, returning `%Suspend{value, resume}`
  - The resume function captures the env, so caller just provides input
  - Run recognizes `%Suspend{}` and bypasses leave_scope
  - When resumed, the result goes through the leave_scope chain
  """

  alias Skuld
  alias Skuld.Env

  @effect_key __MODULE__

  #############################################################################
  ## Operations
  #############################################################################

  @doc "Yield a value and suspend, waiting for input to resume"
  @spec yield(term()) :: Skuld.computation()
  def yield(value) do
    Skuld.effect(@effect_key, {:yield, value})
  end

  @doc "Yield without a value"
  @spec yield() :: Skuld.computation()
  def yield do
    yield(nil)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install the default Yield handler.

  The default handler suspends execution, returning `%Suspend{}` with
  a resume function that captures the env and invokes leave_scope on completion.
  """
  @spec handler(Skuld.env()) :: Skuld.env()
  def handler(env) do
    Env.with_handler(env, @effect_key, &handle/3)
  end

  # Handler: returns Suspend struct with resume that captures env
  # and invokes leave_scope when the resumed computation completes
  defp handle({:yield, value}, env, resume) do
    captured_resume = fn input ->
      {result, final_env} = resume.(input, env)

      # If the result is another Suspend, don't invoke leave_scope yet
      # (it will be invoked when that suspend is eventually resolved)
      case result do
        %Skuld.Suspend{} ->
          {result, final_env}

        _ ->
          # Invoke leave_scope chain on completion
          final_env.leave_scope.(result, final_env)
      end
    end

    {%Skuld.Suspend{value: value, resume: captured_resume}, env}
  end

  #############################################################################
  ## Runner Utilities
  #############################################################################

  @doc """
  Run a computation with a driver function that handles yields.

  The driver receives yielded values and returns `{:continue, input}` or `{:stop, reason}`.
  """
  @spec run_with_driver(
          Skuld.computation(),
          Skuld.env(),
          (term() -> {:continue, term()} | {:stop, term()})
        ) ::
          {:done, term(), Skuld.env()}
          | {:stopped, term(), Skuld.env()}
          | {:thrown, term(), Skuld.env()}
  def run_with_driver(comp, env, driver) do
    case Skuld.run(comp, env) do
      {%Skuld.Suspend{value: yielded, resume: resume}, suspended_env} ->
        case driver.(yielded) do
          {:continue, input} ->
            # Resume returns {result, env} with leave_scope already applied
            {result, new_env} = resume.(input)
            continue_with_driver(result, new_env, driver)

          {:stop, reason} ->
            {:stopped, reason, suspended_env}
        end

      {%Skuld.Throw{error: error}, err_env} ->
        {:thrown, error, err_env}

      {value, final_env} ->
        {:done, value, final_env}
    end
  end

  # Continue processing after a resume
  defp continue_with_driver(%Skuld.Suspend{value: yielded, resume: resume}, env, driver) do
    case driver.(yielded) do
      {:continue, input} ->
        {result, new_env} = resume.(input)
        continue_with_driver(result, new_env, driver)

      {:stop, reason} ->
        {:stopped, reason, env}
    end
  end

  defp continue_with_driver(%Skuld.Throw{error: error}, env, _driver) do
    {:thrown, error, env}
  end

  defp continue_with_driver(value, env, _driver) do
    {:done, value, env}
  end

  @doc """
  Collect all yielded values until completion.

  Resumes with the provided input value (default: nil) each time.
  """
  @spec collect(Skuld.computation(), Skuld.env(), term()) ::
          {:done, term(), [term()], Skuld.env()}
          | {:thrown, term(), [term()], Skuld.env()}
  def collect(comp, env, resume_input \\ nil) do
    case Skuld.run(comp, env) do
      {%Skuld.Suspend{} = suspend, suspended_env} ->
        do_collect(suspend, suspended_env, [], resume_input)

      {%Skuld.Throw{error: error}, err_env} ->
        {:thrown, error, [], err_env}

      {value, final_env} ->
        {:done, value, [], final_env}
    end
  end

  defp do_collect(%Skuld.Suspend{value: yielded, resume: resume}, _env, acc, input) do
    {result, new_env} = resume.(input)

    case result do
      %Skuld.Suspend{} = suspend ->
        do_collect(suspend, new_env, [yielded | acc], input)

      %Skuld.Throw{error: error} ->
        {:thrown, error, Enum.reverse([yielded | acc]), new_env}

      value ->
        {:done, value, Enum.reverse([yielded | acc]), new_env}
    end
  end

  @doc """
  Feed a list of inputs to a computation, collecting yields.

  Each yield consumes one input. If inputs run out, stops with remaining computation.
  """
  @spec feed(Skuld.computation(), Skuld.env(), [term()]) ::
          {:done, term(), [term()], Skuld.env()}
          | {:suspended, term(), (term() -> {Skuld.result(), Skuld.env()}), [term()], Skuld.env()}
          | {:thrown, term(), [term()], Skuld.env()}
  def feed(comp, env, inputs) do
    case Skuld.run(comp, env) do
      {%Skuld.Suspend{} = suspend, suspended_env} ->
        do_feed(suspend, suspended_env, [], inputs)

      {%Skuld.Throw{error: error}, err_env} ->
        {:thrown, error, [], err_env}

      {value, final_env} ->
        {:done, value, [], final_env}
    end
  end

  defp do_feed(%Skuld.Suspend{value: yielded, resume: resume}, env, yielded_acc, []) do
    {:suspended, yielded, resume, Enum.reverse(yielded_acc), env}
  end

  defp do_feed(%Skuld.Suspend{value: yielded, resume: resume}, _env, yielded_acc, [input | rest]) do
    {result, new_env} = resume.(input)

    case result do
      %Skuld.Suspend{} = suspend ->
        do_feed(suspend, new_env, [yielded | yielded_acc], rest)

      %Skuld.Throw{error: error} ->
        {:thrown, error, Enum.reverse([yielded | yielded_acc]), new_env}

      value ->
        {:done, value, Enum.reverse([yielded | yielded_acc]), new_env}
    end
  end
end
