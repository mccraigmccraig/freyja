defmodule Skuld.Effects.EffectLogger do
  @moduledoc """
  Effect logging and replay for Skuld via handler wrapping.

  ## Logging

  Wraps existing handlers to capture effect calls (requests and responses)
  as serializable log entries. Must be applied innermost (first in pipe chain)
  so it can see handlers installed by outer `with_handler` calls.

  ## Replay

  Installs "replay" handlers that return logged responses instead of
  executing real effects. Pure computation segments run normally.

  ## Log Entry Types

  All entries are structs from `Skuld.Effects.EffectLogger.LogEntry`:

  - `Completed` - Simple effect completed synchronously
  - `Thrown` - Effect threw an error
  - `Started` - Suspending effect began (for Yield, etc.)
  - `Suspended` - Effect yielded a value
  - `Resumed` - Suspended effect was resumed with input
  - `Finished` - Suspending effect completed after resume(s)

  See `Skuld.Effects.EffectLogger.LogEntry` for full documentation.

  ## Example

      # EffectLogger must be innermost to see handlers installed by outer with_handler
      {result_with_log, env} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Reader.with_handler(:config)
        |> Comp.run(Env.new())

      # result_with_log is {original_result, log}
      {result, log} = result_with_log
  """

  alias Skuld.Comp
  alias Skuld.Comp.Env
  alias Skuld.Comp.ISentinel
  alias Skuld.Comp.Types

  alias __MODULE__.LogEntry
  alias LogEntry.Completed
  alias LogEntry.Finished
  alias LogEntry.Resumed
  alias LogEntry.Started
  alias LogEntry.Suspended
  alias LogEntry.Thrown

  @log_key {__MODULE__, :log}
  @replay_key {__MODULE__, :replay}

  #############################################################################
  ## Logging
  #############################################################################

  @doc """
  Wrap a computation with effect logging.

  Returns a computation that, when run, logs all effect calls and returns
  `{original_result, log}` as the result.

  Must be applied innermost (first in the pipe chain) so it runs after
  outer `with_handler` calls have installed their handlers.

  ## Options

  - `:effects` - list of effect signatures to log (default: all handlers in evidence)
  - `:timestamp_fn` - function to generate timestamps (default: `DateTime.utc_now/0`)
  - `:id_fn` - function to generate unique IDs (default: `make_ref/0`)

  ## Example

      {result_with_log, _env} =
        my_comp
        |> EffectLogger.with_logging()
        |> State.with_handler(0)
        |> Comp.run(Env.new())

      {result, log} = result_with_log
  """
  @spec with_logging(Types.computation(), keyword()) :: Types.computation()
  def with_logging(comp, opts \\ []) do
    timestamp_fn = Keyword.get(opts, :timestamp_fn, &DateTime.utc_now/0)
    id_fn = Keyword.get(opts, :id_fn, &make_ref/0)
    effects_opt = Keyword.get(opts, :effects)

    comp
    |> Comp.scoped(fn env ->
      effects_to_log = effects_opt || Map.keys(env.evidence)

      # Setup: initialize log and interpose logging handlers
      env_with_log = Env.put_state(env, @log_key, [])

      logged_env =
        Enum.reduce(effects_to_log, env_with_log, fn sig, acc_env ->
          case acc_env.evidence[sig] do
            nil ->
              # No handler for this effect - skip
              acc_env

            handler ->
              logged_handler = make_logging_handler(sig, handler, timestamp_fn, id_fn)
              Env.with_handler(acc_env, sig, logged_handler)
          end
        end)

      # Finally: extract log and transform result to {result, log}
      finally_k = fn result, final_env ->
        log = Env.get_state(final_env, @log_key, [])
        cleaned_env = clean_log_state(final_env)
        {{result, Enum.reverse(log)}, cleaned_env}
      end

      {logged_env, finally_k}
    end)
  end

  defp make_logging_handler(sig, original_handler, timestamp_fn, id_fn) do
    fn args, env, k ->
      log_id = id_fn.()
      started_at = timestamp_fn.()

      # Track whether this effect was logged via k (normal completion)
      flag_key = {:effect_logged, log_id}
      Process.put(flag_key, false)

      # Wrap k to capture the result when the handler calls it
      logging_k = fn value, env_after_effect ->
        # Mark that we logged this effect
        Process.put(flag_key, true)

        # Log the effect completion BEFORE continuing
        entry = %Completed{
          id: log_id,
          effect: sig,
          args: args,
          result: value,
          timestamp: started_at
        }

        logged_env = append_log(env_after_effect, entry)
        # Now continue with the rest of the computation
        k.(value, logged_env)
      end

      # Call original handler with logging k
      {result, result_env} = Comp.call_handler(original_handler, args, env, logging_k)

      # Clean up flag
      was_logged = Process.delete(flag_key)

      # Handle outcomes that don't go through k (sentinels)
      if ISentinel.sentinel?(result) do
        case ISentinel.get_resume(result) do
          nil ->
            # Terminal sentinel (Throw, etc.) - only log if this handler threw
            if was_logged do
              # Sentinel from nested effect - just pass through
              {result, result_env}
            else
              # This handler produced the sentinel - log it
              %{error: error} = ISentinel.serializable_payload(result)

              entry = %Thrown{
                id: log_id,
                effect: sig,
                args: args,
                error: error,
                timestamp: started_at
              }

              {result, append_log(result_env, entry)}
            end

          inner_resume ->
            # Resumable sentinel (Suspend, etc.) - log lifecycle
            start_entry = %Started{
              id: log_id,
              effect: sig,
              args: args,
              timestamp: started_at
            }

            %{yielded: yielded} = ISentinel.serializable_payload(result)

            suspend_entry = %Suspended{
              id: log_id,
              yielded: yielded,
              timestamp: timestamp_fn.()
            }

            logged_env =
              result_env
              |> append_log(start_entry)
              |> append_log(suspend_entry)

            # Wrap the resume to log when it's called
            logged_resume = make_logged_resume(inner_resume, log_id, timestamp_fn)
            new_sentinel = ISentinel.with_resume(result, logged_resume)

            {new_sentinel, logged_env}
        end
      else
        # Normal value - logging already happened in logging_k
        {result, result_env}
      end
    end
  end

  # Create a logged resume function that wraps the original
  defp make_logged_resume(inner_resume, log_id, timestamp_fn) do
    fn input ->
      resume_entry = %Resumed{
        id: log_id,
        input: input,
        timestamp: timestamp_fn.()
      }

      # Call original resume (arity-1)
      {res_result, res_env} = inner_resume.(input)

      # Log the resume entry
      res_env_logged = append_log(res_env, resume_entry)

      if ISentinel.sentinel?(res_result) do
        case ISentinel.get_resume(res_result) do
          nil ->
            # Terminal sentinel - pass through with logged env
            {res_result, res_env_logged}

          r ->
            # Re-suspended - log and wrap the new resume
            %{yielded: yielded} = ISentinel.serializable_payload(res_result)

            re_suspend_entry = %Suspended{
              id: log_id,
              yielded: yielded,
              timestamp: timestamp_fn.()
            }

            logged_r = make_logged_resume(r, log_id, timestamp_fn)
            new_sentinel = ISentinel.with_resume(res_result, logged_r)

            {new_sentinel, append_log(res_env_logged, re_suspend_entry)}
        end
      else
        # Normal completion - log it
        complete_entry = %Finished{
          id: log_id,
          result: res_result,
          timestamp: timestamp_fn.()
        }

        {res_result, append_log(res_env_logged, complete_entry)}
      end
    end
  end

  defp append_log(env, entry) do
    %{env | state: Map.update!(env.state, @log_key, fn log -> [entry | log] end)}
  end

  defp clean_log_state(env) do
    %{env | state: Map.delete(env.state, @log_key)}
  end

  #############################################################################
  ## Replay
  #############################################################################

  @doc """
  Wrap a computation for replay mode using a previously captured log.

  Effects are short-circuited with logged responses instead of executing
  real handlers. Pure computation segments run normally.

  Must be applied innermost (first in the pipe chain) so it runs after
  outer `with_handler` calls have installed their handlers.

  ## Options

  - `:on_missing` - what to do when an effect isn't in the log:
    - `:error` (default) - raise an error
    - `:execute` - fall through to real handler

  ## Example

      {result, _env} =
        my_comp
        |> EffectLogger.replay(log)
        |> State.with_handler(0)
        |> Comp.run(Env.new())
  """
  @spec replay(Types.computation(), [LogEntry.t()], keyword()) :: Types.computation()
  def replay(comp, log, opts \\ []) do
    fn env, k ->
      on_missing = Keyword.get(opts, :on_missing, :error)

      # Convert log to a queue for sequential consumption
      log_queue = :queue.from_list(log)
      env_with_replay = Env.put_state(env, @replay_key, log_queue)

      # Interpose replay handlers on all logged effects
      logged_effects =
        log
        |> Enum.map(& &1.effect)
        |> Enum.uniq()

      replay_env =
        Enum.reduce(logged_effects, env_with_replay, fn sig, acc_env ->
          original_handler = acc_env.evidence[sig]
          replay_handler = make_replay_handler(sig, original_handler, on_missing)
          Env.with_handler(acc_env, sig, replay_handler)
        end)

      # Run inner computation with replay handlers
      Comp.call(comp, replay_env, fn result, final_env ->
        cleaned_env = clean_replay_state(final_env)
        k.(result, cleaned_env)
      end)
    end
  end

  defp make_replay_handler(sig, original_handler, on_missing) do
    fn args, env, k ->
      log_queue = Env.get_state(env, @replay_key)

      case :queue.out(log_queue) do
        {{:value, entry}, rest_queue} ->
          # Check if this entry matches the current effect
          if matches_effect?(entry, sig, args) do
            env_updated = Env.put_state(env, @replay_key, rest_queue)

            case entry do
              %Completed{result: result} ->
                # Simple effect - return logged result
                k.(result, env_updated)

              %Started{} ->
                # Suspending effect - need to handle the full lifecycle
                replay_suspending_effect(entry, env_updated, k)

              %Thrown{error: error} ->
                # Effect threw - return Throw sentinel
                {%Comp.Throw{error: error}, env_updated}
            end
          else
            # Log mismatch - divergence detected
            handle_missing(on_missing, sig, args, env, k, original_handler)
          end

        {:empty, _} ->
          # Log exhausted - new effect not in log
          handle_missing(on_missing, sig, args, env, k, original_handler)
      end
    end
  end

  defp matches_effect?(%Completed{effect: effect, args: logged_args}, sig, args) do
    effect == sig && logged_args == args
  end

  defp matches_effect?(%Thrown{effect: effect, args: logged_args}, sig, args) do
    effect == sig && logged_args == args
  end

  defp matches_effect?(%Started{effect: effect, args: logged_args}, sig, args) do
    effect == sig && logged_args == args
  end

  defp matches_effect?(_, _, _), do: false

  defp replay_suspending_effect(%Started{id: log_id}, env, k) do
    # Find the corresponding suspended/resumed/completed entries
    log_queue = Env.get_state(env, @replay_key)

    # Consume entries until we find completion or another suspension
    case consume_until_completion(log_queue, log_id) do
      {:completed, result, rest_queue} ->
        env_updated = Env.put_state(env, @replay_key, rest_queue)
        k.(result, env_updated)

      {:suspended, _yielded, input, rest_queue} ->
        # The effect suspended and was resumed with input
        env_updated = Env.put_state(env, @replay_key, rest_queue)
        # Continue as if we got that input
        k.(input, env_updated)

      {:thrown, error, rest_queue} ->
        env_updated = Env.put_state(env, @replay_key, rest_queue)
        {%Comp.Throw{error: error}, env_updated}
    end
  end

  defp consume_until_completion(queue, log_id) do
    case :queue.out(queue) do
      {{:value, %Finished{id: ^log_id, result: result}}, rest} ->
        {:completed, result, rest}

      {{:value, %Suspended{id: ^log_id}}, rest} ->
        # Look for the resume
        case :queue.out(rest) do
          {{:value, %Resumed{id: ^log_id, input: input}}, rest2} ->
            # Check what happens after resume
            consume_until_completion_after_resume(rest2, log_id, input)

          _ ->
            # No resume found - effect is still suspended
            {:suspended, nil, nil, rest}
        end

      {{:value, %Thrown{id: ^log_id, error: error}}, rest} ->
        {:thrown, error, rest}

      {{:value, _other}, rest} ->
        # Skip unrelated entries
        consume_until_completion(rest, log_id)

      {:empty, _} ->
        # Log ended without completion - shouldn't happen in valid log
        {:thrown, :replay_log_incomplete, queue}
    end
  end

  defp consume_until_completion_after_resume(queue, log_id, input) do
    case :queue.out(queue) do
      {{:value, %Finished{id: ^log_id}}, rest} ->
        # Completed after resume - return the input that was used
        {:suspended, nil, input, rest}

      {{:value, %Suspended{id: ^log_id}}, _rest} ->
        # Re-suspended - continue looking
        consume_until_completion(queue, log_id)

      {{:value, _other}, rest} ->
        consume_until_completion_after_resume(rest, log_id, input)

      {:empty, _} ->
        {:suspended, nil, input, queue}
    end
  end

  defp handle_missing(:error, sig, args, _env, _k, _handler) do
    raise "Replay divergence: effect #{inspect(sig)} with args #{inspect(args)} not found in log"
  end

  defp handle_missing(:execute, _sig, args, env, k, handler) do
    # Fall through to real handler
    Comp.call_handler(handler, args, env, k)
  end

  defp clean_replay_state(env) do
    %{env | state: Map.delete(env.state, @replay_key)}
  end
end
