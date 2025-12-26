defmodule Skuld.Effects.Writer do
  @moduledoc """
  Writer effect for Skuld - accumulate a log during computation.

  ## Operations

  - `tell(msg)` - append message to log
  - `peek()` - read current log without modification
  - `listen(comp)` - run computation and capture its log output

  ## Example

      import Skuld
      alias Skuld.Effects.Writer

      comp = bind(Writer.tell("step 1"), fn _ ->
        bind(Writer.tell("step 2"), fn _ ->
          pure(:done)
        end)
      end)

      env = Env.new() |> Writer.handler()
      {result, final_env} = run(comp, env)
      # result = :done
      # Writer.get_log(final_env) = ["step 2", "step 1"] (reverse chronological)

  ## Listen Example

      comp = Writer.listen(
        bind(Writer.tell("inner"), fn _ -> pure(42) end)
      )

      # Returns: {42, ["inner"]}

  ## Scoped Operations and Throw

  The scoped operations (`listen`, `pass`, `censor`) use a peek-before/peek-after
  pattern to calculate captured logs. This means on abnormal exit (throw):

  - Logs written before the throw **persist** in state (not rolled back)
  - `listen` does not capture partial logs - the throw propagates out
  - `censor` does not apply its transform - logs leak out untransformed

  This "fire-and-forget" semantic is intentional for logging (you typically want
  to see logs leading up to an error). If you need transactional log semantics
  (rollback on error), you would need to implement leave_scope cleanup.
  """

  alias Skuld
  alias Skuld.Env

  @effect_key __MODULE__
  @state_key :writer_log

  #############################################################################
  ## Effect Operations
  #############################################################################

  @doc "Append a message to the log"
  @spec tell(term()) :: Skuld.computation()
  def tell(msg) do
    Skuld.effect(@effect_key, {:tell, msg})
  end

  @doc "Read the current log (reverse chronological order)"
  @spec peek() :: Skuld.computation()
  def peek do
    Skuld.effect(@effect_key, :peek)
  end

  @doc """
  Run a computation and capture its log output.

  Returns `{result, captured_log}` where captured_log contains only
  the messages written during the inner computation.

  Uses peek before/after to calculate the captured logs.
  """
  @spec listen(Skuld.computation()) :: Skuld.computation()
  def listen(comp) do
    Skuld.bind(peek(), fn initial_log ->
      Skuld.bind(comp, fn result ->
        Skuld.bind(peek(), fn final_log ->
          # Calculate what was added (new logs are at the front)
          captured = Enum.take(final_log, length(final_log) - length(initial_log))
          Skuld.pure({result, captured})
        end)
      end)
    end)
  end

  @doc """
  Run a computation that returns `{value, log_transform_fn}`.

  The transform function is applied to the logs written during the computation.
  """
  @spec pass(Skuld.computation()) :: Skuld.computation()
  def pass(comp) do
    Skuld.bind(peek(), fn initial_log ->
      Skuld.bind(comp, fn {value, transform_fn} ->
        Skuld.bind(peek(), fn final_log ->
          # Calculate captured logs
          captured = Enum.take(final_log, length(final_log) - length(initial_log))
          # Apply transform
          transformed = transform_fn.(captured)
          # Replace captured logs with transformed version
          # We need to: keep initial_log, replace captured with transformed
          new_log = transformed ++ initial_log

          Skuld.bind(set_log(new_log), fn _ ->
            Skuld.pure(value)
          end)
        end)
      end)
    end)
  end

  @doc "Censor: transform all logs written during a computation"
  @spec censor(Skuld.computation(), (list() -> list())) :: Skuld.computation()
  def censor(comp, transform_fn) do
    pass(
      Skuld.bind(comp, fn result ->
        Skuld.pure({result, transform_fn})
      end)
    )
  end

  # Internal: set the log directly (used by pass)
  defp set_log(new_log) do
    Skuld.effect(@effect_key, {:set_log, new_log})
  end

  #############################################################################
  ## Handler
  #############################################################################

  @doc """
  Install the Writer handler into an environment.

  ## Options

  - `:initial` - initial log entries (default: [])
  """
  @spec handler(Skuld.env(), keyword()) :: Skuld.env()
  def handler(env, opts \\ []) do
    initial = Keyword.get(opts, :initial, [])

    env
    |> Env.put_state(@state_key, initial)
    |> Env.with_handler(@effect_key, &handle/3)
  end

  @doc "Get the accumulated log from the environment"
  @spec get_log(Skuld.env()) :: [term()]
  def get_log(env) do
    Env.get_state(env, @state_key, [])
  end

  # Handler implementation - returns {result, env} via k
  defp handle(args, env, k) do
    case args do
      {:tell, msg} ->
        current = Env.get_state(env, @state_key, [])
        updated = [msg | current]
        new_env = Env.put_state(env, @state_key, updated)
        # Return the updated log as the result (like Freyja's tell)
        k.(updated, new_env)

      :peek ->
        current = Env.get_state(env, @state_key, [])
        k.(current, env)

      {:set_log, new_log} ->
        new_env = Env.put_state(env, @state_key, new_log)
        k.(:ok, new_env)
    end
  end

  #############################################################################
  ## Utilities
  #############################################################################

  @doc "Tell multiple messages"
  @spec tell_many([term()]) :: Skuld.computation()
  def tell_many(messages) do
    Skuld.traverse(messages, &tell/1)
  end

  @doc "Clear the log"
  @spec clear() :: Skuld.computation()
  def clear do
    set_log([])
  end
end
