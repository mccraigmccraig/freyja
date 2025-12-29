defmodule Skuld.Effects.EffectLogger do
  @moduledoc """
  Effect logging and replay for Skuld via handler interposition.

  ## Logging

  Wraps existing handlers to capture effect calls (requests and responses)
  as serializable log entries. Requires handlers to already be installed
  in the evidence.

  ## Replay

  Interposes "replay" handlers that return logged responses instead of
  executing real effects. Pure computation segments run normally.

  ## Log Format

  Each log entry is a map:

      %{
        id: unique_id,
        effect: :state,
        op: :get,
        args: [],
        result: 42,
        timestamp: ~U[2024-01-01 00:00:00Z]
      }

  For effects that suspend (Yield), additional entries track the lifecycle:

      %{id: id, event: :started, effect: :yield, args: [...], timestamp: ...}
      %{id: id, event: :suspended, yielded: value, timestamp: ...}
      %{id: id, event: :resumed, input: value, timestamp: ...}
      %{id: id, event: :completed, result: value, timestamp: ...}
  """

  alias Skuld
  alias Skuld.Env

  @log_key :effect_log

  #############################################################################
  ## Logging
  #############################################################################

  @doc """
  Run a computation with effect logging enabled.

  All effects with handlers in the evidence will be logged.
  Returns `{outcome, log}` where log is a list of log entries (oldest first).

  ## Options

  - `:effects` - list of effect signatures to log (default: all handlers in evidence)
  - `:timestamp_fn` - function to generate timestamps (default: `DateTime.utc_now/0`)
  - `:id_fn` - function to generate unique IDs (default: `make_ref/0`)
  """
  @spec with_logging(Skuld.computation(), Skuld.env(), keyword()) ::
          {Skuld.outcome(), [map()]}
  def with_logging(comp, env, opts \\ []) do
    effects_to_log = Keyword.get(opts, :effects, Map.keys(env.evidence))
    timestamp_fn = Keyword.get(opts, :timestamp_fn, &DateTime.utc_now/0)
    id_fn = Keyword.get(opts, :id_fn, &make_ref/0)

    # Initialize log in env
    env_with_log = Env.put_state(env, @log_key, [])

    # Interpose logging on specified effects
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

    # Run computation
    outcome = Skuld.run(comp, logged_env)

    # Extract log from final env
    {log, cleaned_outcome} = extract_log(outcome)

    {cleaned_outcome, Enum.reverse(log)}
  end

  defp make_logging_handler(sig, original_handler, timestamp_fn, id_fn) do
    fn args, env, k ->
      log_id = id_fn.()
      started_at = timestamp_fn.()

      # Track whether this effect was logged via k (normal completion)
      # Use a process dictionary flag as a simple mechanism
      flag_key = {:effect_logged, log_id}
      Process.put(flag_key, false)

      # Wrap k to capture the result when the handler calls it
      logging_k = fn value, env_after_effect ->
        # Mark that we logged this effect
        Process.put(flag_key, true)

        # Log the effect completion BEFORE continuing
        entry = %{
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
      result = original_handler.(args, env, logging_k)

      # Clean up flag
      was_logged = Process.delete(flag_key)

      # Handle outcomes that don't go through k (throw, suspend)
      case result do
        {:suspended, yielded, inner_resume, susp_env} ->
          # Effect suspended before calling k - log start and suspension
          start_entry = %{
            id: log_id,
            event: :started,
            effect: sig,
            args: args,
            timestamp: started_at
          }

          suspend_entry = %{
            id: log_id,
            event: :suspended,
            yielded: yielded,
            timestamp: timestamp_fn.()
          }

          logged_env =
            susp_env
            |> append_log(start_entry)
            |> append_log(suspend_entry)

          # Wrap the inner resume to log when it's called
          logged_inner_resume = fn input, res_env ->
            resume_entry = %{
              id: log_id,
              event: :resumed,
              input: input,
              timestamp: timestamp_fn.()
            }

            res_env_logged = append_log(res_env, resume_entry)

            case inner_resume.(input, res_env_logged) do
              {:done, value, final_env} ->
                complete_entry = %{
                  id: log_id,
                  event: :completed,
                  result: value,
                  timestamp: timestamp_fn.()
                }

                {:done, value, append_log(final_env, complete_entry)}

              {:suspended, y, r, e} ->
                re_suspend_entry = %{
                  id: log_id,
                  event: :suspended,
                  yielded: y,
                  timestamp: timestamp_fn.()
                }

                {:suspended, y, r, append_log(e, re_suspend_entry)}

              # Thrown errors from nested effects just pass through
              # (they'll be logged at their source)
              other ->
                other
            end
          end

          {:suspended, yielded, logged_inner_resume, logged_env}

        {:thrown, error, err_env} ->
          # Only log if this handler actually threw (didn't call k)
          # If was_logged is true, this is a nested throw bubbling up
          if was_logged do
            # Throw from nested effect - just pass through
            {:thrown, error, err_env}
          else
            # This handler threw - log it
            entry = %{
              id: log_id,
              effect: sig,
              args: args,
              error: error,
              timestamp: started_at
            }

            {:thrown, error, append_log(err_env, entry)}
          end

        # Normal case: handler called k, which returned an outcome
        # The logging already happened in logging_k
        other ->
          other
      end
    end
  end

  defp append_log(env, entry) do
    %{env | state: Map.update!(env.state, @log_key, fn log -> [entry | log] end)}
  end

  defp extract_log(outcome) do
    case outcome do
      {:done, value, env} ->
        log = Env.get_state(env, @log_key, [])
        cleaned_env = clean_log_state(env)
        {log, {:done, value, cleaned_env}}

      {:suspended, yielded, resume, env} ->
        log = Env.get_state(env, @log_key, [])
        cleaned_env = clean_log_state(env)
        {log, {:suspended, yielded, resume, cleaned_env}}

      {:thrown, error, env} ->
        log = Env.get_state(env, @log_key, [])
        cleaned_env = clean_log_state(env)
        {log, {:thrown, error, cleaned_env}}
    end
  end

  defp clean_log_state(env) do
    %{env | state: Map.delete(env.state, @log_key)}
  end

  #############################################################################
  ## Replay
  #############################################################################

  @doc """
  Run a computation in replay mode using a previously captured log.

  Effects are short-circuited with logged responses instead of executing
  real handlers. Pure computation segments run normally.

  Returns the outcome and any new effects that weren't in the log
  (which would indicate divergence from the original execution).

  ## Options

  - `:on_missing` - what to do when an effect isn't in the log:
    - `:error` (default) - raise an error
    - `:execute` - fall through to real handler
  """
  @spec replay(Skuld.computation(), Skuld.env(), [map()], keyword()) :: Skuld.outcome()
  def replay(comp, env, log, opts \\ []) do
    on_missing = Keyword.get(opts, :on_missing, :error)

    # Convert log to a queue for sequential consumption
    log_queue = :queue.from_list(log)
    env_with_replay = Env.put_state(env, :replay_log, log_queue)

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

    outcome = Skuld.run(comp, replay_env)
    clean_replay_state(outcome)
  end

  defp make_replay_handler(sig, original_handler, on_missing) do
    fn args, env, k ->
      log_queue = Env.get_state(env, :replay_log)

      case :queue.out(log_queue) do
        {{:value, entry}, rest_queue} ->
          # Check if this entry matches the current effect
          if matches_effect?(entry, sig, args) do
            env_updated = Env.put_state(env, :replay_log, rest_queue)

            case entry do
              %{result: result} ->
                # Simple effect - return logged result
                k.(result, env_updated)

              %{event: :started} ->
                # Suspending effect - need to handle the full lifecycle
                replay_suspending_effect(entry, env_updated, k)

              %{error: error} ->
                # Effect threw
                {:thrown, error, env_updated}
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

  defp matches_effect?(%{effect: effect, args: logged_args}, sig, args) do
    effect == sig && logged_args == args
  end

  defp matches_effect?(%{effect: effect}, sig, _args) do
    # For lifecycle events, just check effect signature
    effect == sig
  end

  defp matches_effect?(_, _, _), do: false

  defp replay_suspending_effect(%{id: log_id}, env, k) do
    # Find the corresponding suspended/resumed/completed entries
    log_queue = Env.get_state(env, :replay_log)

    # Consume entries until we find completion or another suspension
    case consume_until_completion(log_queue, log_id) do
      {:completed, result, rest_queue} ->
        env_updated = Env.put_state(env, :replay_log, rest_queue)
        k.(result, env_updated)

      {:suspended, _yielded, input, rest_queue} ->
        # The effect suspended and was resumed with input
        env_updated = Env.put_state(env, :replay_log, rest_queue)
        # Continue as if we got that input
        k.(input, env_updated)

      {:thrown, error, rest_queue} ->
        env_updated = Env.put_state(env, :replay_log, rest_queue)
        {:thrown, error, env_updated}
    end
  end

  defp consume_until_completion(queue, log_id) do
    case :queue.out(queue) do
      {{:value, %{id: ^log_id, event: :completed, result: result}}, rest} ->
        {:completed, result, rest}

      {{:value, %{id: ^log_id, event: :suspended}}, rest} ->
        # Look for the resume
        case :queue.out(rest) do
          {{:value, %{id: ^log_id, event: :resumed, input: input}}, rest2} ->
            # Check what happens after resume
            consume_until_completion_after_resume(rest2, log_id, input)

          _ ->
            # No resume found - effect is still suspended
            {:suspended, nil, nil, rest}
        end

      {{:value, %{id: ^log_id, event: :thrown, error: error}}, rest} ->
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
      {{:value, %{id: ^log_id, event: :completed, result: _result}}, rest} ->
        # Completed after resume - return the input that was used
        {:suspended, nil, input, rest}

      {{:value, %{id: ^log_id, event: :suspended}}, _rest} ->
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
    handler.(args, env, k)
  end

  defp clean_replay_state(outcome) do
    case outcome do
      {:done, value, env} ->
        {:done, value, %{env | state: Map.delete(env.state, :replay_log)}}

      {:suspended, yielded, resume, env} ->
        {:suspended, yielded, resume, %{env | state: Map.delete(env.state, :replay_log)}}

      {:thrown, error, env} ->
        {:thrown, error, %{env | state: Map.delete(env.state, :replay_log)}}
    end
  end
end
