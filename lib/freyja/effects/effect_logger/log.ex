defmodule Freyja.Effects.EffectLogger.EffectLogEntry do
  @moduledoc """
  A single effect
  """
  defstruct sig: nil, data: nil, scoped_logs: nil

  @type t :: %__MODULE__{
          sig: any,
          data: any,
          scoped_logs: any
        }

  def new(sig, data) do
    %__MODULE__{sig: sig, data: data}
  end

  def set_scoped_logs(self, scoped_logs) do
    Map.put(self, :scoped_logs, scoped_logs)
  end

  @doc """
  Reconstruct EffectLogEntry from decoded JSON map.
  Note: data field may be nil if it was not serializable.
  """
  def from_json(map) when is_map(map) do
    %__MODULE__{
      sig: map["sig"] && String.to_existing_atom(map["sig"]),
      data: reconstruct_data(map["data"]),
      scoped_logs:
        map["scoped_logs"] && Freyja.Effects.EffectLogger.ScopedLogs.from_json(map["scoped_logs"])
    }
  end

  # Reconstruct effect data structs from JSON maps
  defp reconstruct_data(nil), do: nil

  defp reconstruct_data(%{"__struct__" => struct_name} = data) when is_binary(struct_name) do
    # Convert the struct name string to a module
    module = String.to_existing_atom(struct_name)
    # Convert the map to the struct
    struct(module, atomize_keys(data))
  end

  defp reconstruct_data(data), do: data

  # Convert string keys to atoms (excluding __struct__ which is handled separately)
  defp atomize_keys(map) when is_map(map) do
    map
    |> Map.delete("__struct__")
    |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Enum.into(%{})
  end
end

defimpl Jason.Encoder, for: Freyja.Effects.EffectLogger.EffectLogEntry do
  def encode(value, opts) do
    # Try to encode data if it's serializable, otherwise omit it
    data_value =
      try do
        # Test if data can be encoded
        _ = Jason.encode!(value.data)
        value.data
      rescue
        _ -> nil
      end

    Jason.Encode.map(
      %{
        sig: value.sig,
        data: data_value,
        scoped_logs: value.scoped_logs
      },
      opts
    )
  end
end

defmodule Freyja.Effects.EffectLogger.StepLogEntry do
  @moduledoc """
  logs the progress to interpret a value, which may comprise
  multiple steps through intermediate effects, until one yields
  a value and completes the step (i.e. invokes the next continuation
  from the queue)
  """
  alias Freyja.Effects.EffectLogger.EffectLogEntry

  defstruct effects_stack: [], effects_queue: [], completed?: false, value: nil

  @type t :: %__MODULE__{
          effects_stack: list(EffectLogEntry.t()),
          effects_queue: list(EffectLogEntry.t()),
          completed?: boolean,
          value: any
        }

  def new(sig, data) do
    %__MODULE__{
      effects_stack: [],
      effects_queue: [EffectLogEntry.new(sig, data)],
      completed?: false,
      value: nil
    }
  end

  def push_effect(%__MODULE__{} = self, sig, data) do
    case self.effects_queue do
      # new effect
      [%EffectLogEntry{} = fx_log_entry] ->
        %{
          self
          | effects_stack: [fx_log_entry | self.effects_stack],
            effects_queue: [EffectLogEntry.new(sig, data)]
        }

      # following the log - new effect must match
      [
        %EffectLogEntry{} = fx_log_entry,
        %EffectLogEntry{sig: next_fx_sig, data: next_fx_data} = next_fx_log_entry | rest
      ]
      when sig == next_fx_sig and data == next_fx_data ->
        %{
          self
          | effects_stack: [fx_log_entry | self.effects_stack],
            effects_queue: [next_fx_log_entry | rest]
        }

      _ ->
        raise ArgumentError,
          message:
            "effect diverged from log:\n " <>
              "effect: sig: #{inspect(sig, pretty: true)}, data: #{inspect(data, pretty: true)}" <>
              "log: #{inspect(self, pretty: true)}\n"
    end
  end

  def set_scoped_logs(%__MODULE__{} = self, scoped_logs) do
    case self.effects_queue do
      [%EffectLogEntry{} = int_log_entry | rest] ->
        %{
          self
          | effects_queue: [EffectLogEntry.set_scoped_logs(int_log_entry, scoped_logs) | rest]
        }

      _ ->
        raise ArgumentError,
          message:
            "unexpected scoped_logs: #{inspect(self, pretty: true)}\n" <>
              "#{inspect(scoped_logs, pretty: true)}"
    end
  end

  def set_value(%__MODULE__{} = self, value) do
    case self.effects_queue do
      [%EffectLogEntry{} = fx_log_entry] ->
        %{
          self
          | effects_stack: [fx_log_entry | self.effects_stack],
            effects_queue: [],
            completed?: true,
            value: value
        }

      _ ->
        raise ArgumentError,
          message:
            "unexpected value: #{inspect(value, pretty: true)}" <>
              "#{inspect(self, pretty: true)}\n"
    end
  end

  def prepare_for_retrace(%__MODULE__{} = log_entry) do
    %{
      log_entry
      | effects_stack: [],
        effects_queue: Enum.reverse(log_entry.effects_stack) ++ log_entry.effects_queue
    }
  end

  @doc """
  Reconstruct StepLogEntry from decoded JSON map.
  """
  def from_json(map) when is_map(map) do
    %__MODULE__{
      effects_stack: Enum.map(map["effects_stack"] || [], &EffectLogEntry.from_json/1),
      effects_queue: Enum.map(map["effects_queue"] || [], &EffectLogEntry.from_json/1),
      completed?: map["completed?"],
      value: map["value"]
    }
  end
end

defimpl Jason.Encoder, for: Freyja.Effects.EffectLogger.StepLogEntry do
  def encode(value, opts) do
    Jason.Encode.map(
      %{
        effects_stack: value.effects_stack,
        effects_queue: value.effects_queue,
        completed?: value.completed?,
        value: value.value
      },
      opts
    )
  end
end

# cf interceptor chains
defmodule Freyja.Effects.EffectLogger.Log do
  @moduledoc """
  A structured log of a whole computation
  """
  alias Freyja.Effects.EffectLogger.EffectLogEntry
  alias Freyja.Effects.EffectLogger.StepLogEntry
  alias Freyja.Freer.Impure

  defstruct stack: [], queue: [], replay_allow_final_divergence?: false

  @type t :: %__MODULE__{
          stack: list(StepLogEntry.t()),
          queue: list(StepLogEntry.t()),
          replay_allow_final_divergence?: boolean()
        }

  def new() do
    %__MODULE__{
      stack: [],
      queue: []
    }
  end

  def new(%__MODULE__{} = _parent) do
    %__MODULE__{
      stack: [],
      queue: []
    }
  end

  def log_effect(%__MODULE__{} = log, %Impure{sig: sig, data: data}) do
    case log.queue do
      [] ->
        %{log | queue: [StepLogEntry.new(sig, data)]}

      _ ->
        raise ArgumentError,
          message: "unexpected effect: #{inspect(%{sig: sig, data: data}, pretty: true)}"
    end
  end

  def push_effect(%__MODULE__{} = log, %Impure{sig: sig, data: data}) do
    case log.queue do
      [] ->
        raise ArgumentError,
          message: "unexpected effect: #{inspect(%{sig: sig, data: data}, pretty: true)}"

      [%StepLogEntry{effects_queue: [_prev | _]} = le | rest] ->
        updated_sle = StepLogEntry.push_effect(le, sig, data)
        %{log | queue: [updated_sle | rest]}
    end
  end

  @doc """
  set the scoped_logs as the scoped_logs of the current effect in the
  currently open step of the log - closes the step in the process
  because a scoped computation always returns a value
  """
  def set_scoped_logs(
        %__MODULE__{} = parent_log,
        # ideally this would be a ScopedLogs match - but it's a
        # circular reference so it's not
        %_{} = scoped_logs
      ) do
    case parent_log.queue do
      [%StepLogEntry{} = parent_step_log_entry | rest] ->
        %{
          parent_log
          | queue: [
              StepLogEntry.set_scoped_logs(
                parent_step_log_entry,
                scoped_logs
              )
              | rest
            ]
        }

      _ ->
        raise ArgumentError,
          message:
            "unexpected scoped_logs: #{inspect(scoped_logs, pretty: true)}\n" <>
              "parent_log: #{inspect(parent_log, pretty: true)}"
    end
  end

  def log_interpreted_effect_value(%__MODULE__{} = log, effect_value) do
    case log.queue do
      [%StepLogEntry{} = log_entry] ->
        %{
          log
          | stack: [StepLogEntry.set_value(log_entry, effect_value) | log.stack],
            queue: []
        }

      _ ->
        raise ArgumentError,
          message:
            "unexpected effect value: #{inspect(effect_value, pretty: true)}\n" <>
              "#{inspect(log, pretty: true)}"
    end
  end

  def consume_log_entry(%__MODULE__{} = log) do
    case log.queue do
      [%StepLogEntry{} = log_entry | rest] ->
        %{
          log
          | stack: [log_entry | log.stack],
            queue: rest
        }
    end
  end

  def prepare_for_retrace(%__MODULE__{} = log) do
    %__MODULE__{
      log
      | stack: [],
        queue:
          (Enum.reverse(log.stack) ++ log.queue) |> Enum.map(&StepLogEntry.prepare_for_retrace/1)
    }
  end

  @doc """
  Reconstruct Log from decoded JSON map.
  """
  def from_json(map) when is_map(map) do
    %__MODULE__{
      stack: Enum.map(map["stack"] || [], &StepLogEntry.from_json/1),
      queue: Enum.map(map["queue"] || [], &StepLogEntry.from_json/1),
      replay_allow_final_divergence?: map["replay_allow_final_divergence?"] || false
    }
  end

  @doc """
  Create a log for resuming from an error.
  Allows divergence at the final log entry, enabling debugging scenarios where
  the code has been fixed and the error no longer occurs.
  """
  def for_error_resume(log) do
    %{log | replay_allow_final_divergence?: true}
  end
end

defimpl Jason.Encoder, for: Freyja.Effects.EffectLogger.Log do
  def encode(value, opts) do
    Jason.Encode.map(
      %{
        stack: value.stack,
        queue: value.queue,
        replay_allow_final_divergence?: value.replay_allow_final_divergence?
      },
      opts
    )
  end
end

defmodule Freyja.Effects.EffectLogger.ScopedLogs do
  @moduledoc """
  Holds multiple sibling scoped logs (e.g., from List.fx_map iterations)
  Uses queue/stack pattern for replay support.
  """
  alias Freyja.Effects.EffectLogger.Log

  defstruct scoped_log_queue: [], scoped_log_stack: []

  @type t :: %__MODULE__{
          scoped_log_queue: list(Log.t()),
          scoped_log_stack: list(Log.t())
        }

  def new() do
    %__MODULE__{scoped_log_queue: [], scoped_log_stack: []}
  end

  def new(%Log{} = first_log) do
    %__MODULE__{scoped_log_queue: [first_log], scoped_log_stack: []}
  end

  @doc """
  Moves current log from queue to stack, adds new log to queue
  Called when a sibling scoped computation completes
  """
  def push_scoped_log(%__MODULE__{scoped_log_queue: [current | rest]} = scoped_logs, new_log) do
    finalized_current = Log.prepare_for_retrace(current)

    %{
      scoped_logs
      | scoped_log_queue: [new_log | rest],
        scoped_log_stack: [finalized_current | scoped_logs.scoped_log_stack]
    }
  end

  @doc """
  Prepares ScopedLogs for retrace by moving all logs from stack to queue.
  Similar to Log.prepare_for_retrace - reverses stack, concatenates with queue, clears stack.
  Called when parent computation receives ScopedLogs via scoped_ok/scoped_error.
  """
  def prepare_scoped_logs_for_retrace(%__MODULE__{} = scoped_logs) do
    %{
      scoped_logs
      | scoped_log_stack: [],
        scoped_log_queue:
          Enum.reverse(scoped_logs.scoped_log_stack) ++ scoped_logs.scoped_log_queue
    }
  end

  @doc """
  Reconstruct ScopedLogs from decoded JSON map.
  """
  def from_json(map) when is_map(map) do
    %__MODULE__{
      scoped_log_queue: Enum.map(map["scoped_log_queue"] || [], &Log.from_json/1),
      scoped_log_stack: Enum.map(map["scoped_log_stack"] || [], &Log.from_json/1)
    }
  end
end

defimpl Jason.Encoder, for: Freyja.Effects.EffectLogger.ScopedLogs do
  def encode(value, opts) do
    Jason.Encode.map(
      %{
        scoped_log_queue: value.scoped_log_queue,
        scoped_log_stack: value.scoped_log_stack
      },
      opts
    )
  end
end

defprotocol Freyja.Effects.EffectLogger.ILog do
  @moduledoc """
  Common interface for Log and ScopedLogs
  """
  def log_effect(log, impure)
  def push_effect(log, impure)
  def log_interpreted_effect_value(log, value)
  def consume_log_entry(log)
  def prepare_for_retrace(log)
  def set_scoped_logs(log, scoped_log)
  def current_log(log)
end

defimpl Freyja.Effects.EffectLogger.ILog, for: Freyja.Effects.EffectLogger.Log do
  alias Freyja.Effects.EffectLogger.Log

  def log_effect(log, impure), do: Log.log_effect(log, impure)
  def push_effect(log, impure), do: Log.push_effect(log, impure)
  def log_interpreted_effect_value(log, value), do: Log.log_interpreted_effect_value(log, value)
  def consume_log_entry(log), do: Log.consume_log_entry(log)
  def prepare_for_retrace(log), do: Log.prepare_for_retrace(log)
  def set_scoped_logs(log, scoped_logs), do: Log.set_scoped_logs(log, scoped_logs)
  def current_log(log), do: log
end

defimpl Freyja.Effects.EffectLogger.ILog, for: Freyja.Effects.EffectLogger.ScopedLogs do
  alias Freyja.Effects.EffectLogger.Log
  alias Freyja.Effects.EffectLogger.ScopedLogs

  def log_effect(%ScopedLogs{scoped_log_queue: [current | rest]} = scoped_logs, impure) do
    updated_current = Log.log_effect(current, impure)
    %{scoped_logs | scoped_log_queue: [updated_current | rest]}
  end

  def push_effect(%ScopedLogs{scoped_log_queue: [current | rest]} = scoped_logs, impure) do
    updated_current = Log.push_effect(current, impure)
    %{scoped_logs | scoped_log_queue: [updated_current | rest]}
  end

  def log_interpreted_effect_value(
        %ScopedLogs{scoped_log_queue: [current | rest]} = scoped_logs,
        value
      ) do
    updated_current = Log.log_interpreted_effect_value(current, value)
    %{scoped_logs | scoped_log_queue: [updated_current | rest]}
  end

  def consume_log_entry(%ScopedLogs{scoped_log_queue: [current | rest]} = scoped_logs) do
    updated_current = Log.consume_log_entry(current)
    %{scoped_logs | scoped_log_queue: [updated_current | rest]}
  end

  def prepare_for_retrace(%ScopedLogs{scoped_log_queue: [current | rest]} = scoped_logs) do
    # Just prepare the current log - sibling logs were already prepared when they finalized
    updated_current = Log.prepare_for_retrace(current)
    %{scoped_logs | scoped_log_queue: [updated_current | rest]}
  end

  def set_scoped_logs(
        %ScopedLogs{scoped_log_queue: [current | rest]} = scoped_logs,
        inner_scoped_logs
      ) do
    # Delegate to current log - handles nested scoped effect
    updated_current = Log.set_scoped_logs(current, inner_scoped_logs)
    %{scoped_logs | scoped_log_queue: [updated_current | rest]}
  end

  def current_log(%ScopedLogs{scoped_log_queue: [current | _]}), do: current
end
