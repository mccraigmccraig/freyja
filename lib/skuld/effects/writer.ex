defmodule Skuld.Effects.Writer do
  @moduledoc """
  Writer effect for Skuld - accumulate a log during computation.

  ## Operations

  - `tell(msg)` - append message to log
  - `peek()` - read current log without modification
  - `listen(comp)` - run computation and capture its log output

  ## Example

      alias Skuld.Comp
      alias Skuld.Comp.Env
      alias Skuld.Effects.Writer

      comp =
        Comp.bind(Writer.tell("step 1"), fn _ ->
          Comp.bind(Writer.tell("step 2"), fn _ ->
            Comp.bind(Writer.peek(), fn log ->
              Comp.pure({:done, log})
            end)
          end)
        end)

      {{result, log}, _env} =
        comp
        |> Writer.with_handler()
        |> Comp.run(Env.new())

      # result = :done
      # log = ["step 2", "step 1"] (reverse chronological)

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

  @behaviour Skuld.Comp.IHandler

  import Skuld.Comp.DefOp

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.Types

  @sig __MODULE__
  @state_key :writer_log

  #############################################################################
  ## Operation Structs
  #############################################################################

  def_op(Tell, [:msg])
  def_op(Peek)
  def_op(SetLog, [:log])

  #############################################################################
  ## Effect Operations
  #############################################################################

  @doc "Append a message to the log"
  @spec tell(term()) :: Types.computation()
  def tell(msg) do
    Comp.effect(@sig, %Tell{msg: msg})
  end

  @doc "Read the current log (reverse chronological order)"
  @spec peek() :: Types.computation()
  def peek do
    Comp.effect(@sig, %Peek{})
  end

  @doc """
  Run a computation and capture its log output.

  Returns `{result, captured_log}` where captured_log contains only
  the messages written during the inner computation.

  Uses peek before/after to calculate the captured logs.
  """
  @spec listen(Types.computation()) :: Types.computation()
  def listen(comp) do
    Comp.bind(peek(), fn initial_log ->
      Comp.bind(comp, fn result ->
        Comp.bind(peek(), fn final_log ->
          # Calculate what was added (new logs are at the front)
          captured = Enum.take(final_log, length(final_log) - length(initial_log))
          Comp.pure({result, captured})
        end)
      end)
    end)
  end

  @doc """
  Run a computation that returns `{value, log_transform_fn}`.

  The transform function is applied to the logs written during the computation.
  """
  @spec pass(Types.computation()) :: Types.computation()
  def pass(comp) do
    Comp.bind(peek(), fn initial_log ->
      Comp.bind(comp, fn {value, transform_fn} ->
        Comp.bind(peek(), fn final_log ->
          # Calculate captured logs
          captured = Enum.take(final_log, length(final_log) - length(initial_log))
          # Apply transform
          transformed = transform_fn.(captured)
          # Replace captured logs with transformed version
          # We need to: keep initial_log, replace captured with transformed
          new_log = transformed ++ initial_log

          Comp.bind(set_log(new_log), fn _ ->
            Comp.pure(value)
          end)
        end)
      end)
    end)
  end

  @doc "Censor: transform all logs written during a computation"
  @spec censor(Types.computation(), (list() -> list())) :: Types.computation()
  def censor(comp, transform_fn) do
    pass(
      Comp.bind(comp, fn result ->
        Comp.pure({result, transform_fn})
      end)
    )
  end

  # Internal: set the log directly (used by pass)
  defp set_log(new_log) do
    Comp.effect(@sig, %SetLog{log: new_log})
  end

  #############################################################################
  ## Handler Installation
  #############################################################################

  @doc """
  Install a scoped Writer handler for a computation.

  Installs the Writer handler and initializes the log for the duration of `comp`.
  Both the handler and log state are restored/removed when `comp` completes or throws.

  The argument order is pipe-friendly.

  ## Example

      # Wrap a computation with its own Writer log
      comp_with_writer =
        comp do
          _ <- Writer.tell("step 1")
          _ <- Writer.tell("step 2")
          return(:done)
        end
        |> Writer.with_handler()

      # With initial log entries
      comp_with_initial =
        my_comp
        |> Writer.with_handler(["existing entry"])

      # Compose multiple handlers with pipes
      my_comp
      |> Writer.with_handler()
      |> State.with_handler(0)
      |> Comp.run(Env.new())
  """
  @spec with_handler(Types.computation(), list()) :: Types.computation()
  def with_handler(comp, initial \\ []) do
    comp
    |> Comp.scoped(fn env ->
      previous_log = Env.get_state(env, @state_key)
      modified = Env.put_state(env, @state_key, initial)

      finally_k = fn value, e ->
        restored_env =
          case previous_log do
            nil -> %{e | state: Map.delete(e.state, @state_key)}
            log -> Env.put_state(e, @state_key, log)
          end

        {value, restored_env}
      end

      {modified, finally_k}
    end)
    |> Comp.with_handler(@sig, &__MODULE__.handle/3)
  end

  @doc "Get the accumulated log from the environment"
  @spec get_log(Types.env()) :: [term()]
  def get_log(env) do
    Env.get_state(env, @state_key, [])
  end

  #############################################################################
  ## IHandler Implementation
  #############################################################################

  @impl Skuld.Comp.IHandler
  def handle(%Tell{msg: msg}, env, k) do
    current = Env.get_state(env, @state_key, [])
    updated = [msg | current]
    new_env = Env.put_state(env, @state_key, updated)
    # Return the updated log as the result (like Freyja's tell)
    k.(updated, new_env)
  end

  @impl Skuld.Comp.IHandler
  def handle(%Peek{}, env, k) do
    current = Env.get_state(env, @state_key, [])
    k.(current, env)
  end

  @impl Skuld.Comp.IHandler
  def handle(%SetLog{log: new_log}, env, k) do
    new_env = Env.put_state(env, @state_key, new_log)
    k.(:ok, new_env)
  end

  #############################################################################
  ## Utilities
  #############################################################################

  @doc "Tell multiple messages"
  @spec tell_many([term()]) :: Types.computation()
  def tell_many(messages) do
    Comp.traverse(messages, &tell/1)
  end

  @doc "Clear the log"
  @spec clear() :: Types.computation()
  def clear do
    set_log([])
  end
end
