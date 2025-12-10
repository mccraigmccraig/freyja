defmodule Skuld.Effects.Yield do
  @moduledoc """
  Yield effect - coroutine-style suspension and resumption.

  Uses CPS style (arity-2 computations) because yield captures the continuation.
  This is a control effect that requires continuation capture.
  """

  alias Skuld
  alias Skuld.Env

  @effect_key :yield

  #############################################################################
  ## Operations (CPS style - arity-2)
  #############################################################################

  @doc "Yield a value and suspend, waiting for input to resume"
  @spec yield(term()) :: Skuld.cps_computation()
  def yield(value) do
    Skuld.effect(@effect_key, {:yield, value})
  end

  @doc "Yield without a value"
  @spec yield() :: Skuld.cps_computation()
  def yield do
    yield(nil)
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install the default Yield handler.

  The default handler suspends execution, returning the continuation.
  """
  @spec handler(Skuld.env()) :: Skuld.env()
  def handler(env) do
    Env.with_handler(env, @effect_key, &handle/3)
  end

  # Control handler (arity-3): fn args, env, resume -> outcome
  defp handle({:yield, value}, env, resume) do
    {:suspended, value, resume, env}
  end

  #############################################################################
  ## Runner Utilities
  #############################################################################

  @doc """
  Run a computation with a driver function that handles yields.

  The driver receives yielded values and returns `{:continue, input}` or `{:stop, reason}`.
  The computation must be CPS (arity-2). Use Skuld.to_cps if needed.
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
      {:done, value, final_env} ->
        {:done, value, final_env}

      {:suspended, yielded, resume, suspended_env} ->
        case driver.(yielded) do
          {:continue, input} ->
            run_with_driver(
              fn e, _r -> resume.(input, e) end,
              suspended_env,
              driver
            )

          {:stop, reason} ->
            {:stopped, reason, suspended_env}
        end

      {:thrown, error, err_env} ->
        {:thrown, error, err_env}
    end
  end

  @doc """
  Collect all yielded values until completion.

  Resumes with the provided input value (default: nil) each time.
  """
  @spec collect(Skuld.computation(), Skuld.env(), term()) ::
          {:done, term(), [term()], Skuld.env()}
          | {:thrown, term(), [term()], Skuld.env()}
  def collect(comp, env, resume_input \\ nil) do
    do_collect(Skuld.run(comp, env), [], resume_input)
  end

  defp do_collect({:done, value, final_env}, acc, _input) do
    {:done, value, Enum.reverse(acc), final_env}
  end

  defp do_collect({:suspended, yielded, resume, env}, acc, input) do
    next_outcome = resume.(input, env)
    do_collect(next_outcome, [yielded | acc], input)
  end

  defp do_collect({:thrown, error, env}, acc, _input) do
    {:thrown, error, Enum.reverse(acc), env}
  end

  @doc """
  Feed a list of inputs to a computation, collecting yields.

  Each yield consumes one input. If inputs run out, stops with remaining computation.
  """
  @spec feed(Skuld.computation(), Skuld.env(), [term()]) ::
          {:done, term(), [term()], Skuld.env()}
          | {:suspended, term(), Skuld.resume(), [term()], Skuld.env()}
          | {:thrown, term(), [term()], Skuld.env()}
  def feed(comp, env, inputs) do
    do_feed(Skuld.run(comp, env), [], inputs)
  end

  defp do_feed({:done, value, final_env}, yielded_acc, _inputs) do
    {:done, value, Enum.reverse(yielded_acc), final_env}
  end

  defp do_feed({:suspended, yielded, resume, env}, yielded_acc, []) do
    {:suspended, yielded, resume, Enum.reverse(yielded_acc), env}
  end

  defp do_feed({:suspended, yielded, resume, env}, yielded_acc, [input | rest]) do
    next_outcome = resume.(input, env)
    do_feed(next_outcome, [yielded | yielded_acc], rest)
  end

  defp do_feed({:thrown, error, env}, yielded_acc, _inputs) do
    {:thrown, error, Enum.reverse(yielded_acc), env}
  end
end
