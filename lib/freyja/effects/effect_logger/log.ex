defmodule Freyja.Effects.EffectLogger.EffectLogEntry do
  @moduledoc """
  A single effect
  """
  alias Freyja.Run.SerializableStruct

  defstruct sig: nil, data: nil

  @type t :: %__MODULE__{
          sig: any,
          data: any
        }

  def new(sig, data) do
    %__MODULE__{sig: sig, data: data}
  end

  @doc """
  Reconstruct EffectLogEntry from decoded JSON map.
  Note: data field may be nil if it was not serializable.
  """
  def from_json(map) when is_map(map) do
    %__MODULE__{
      sig: map["sig"] && String.to_existing_atom(map["sig"]),
      data: reconstruct_data(map["data"])
    }
  end

  # Reconstruct effect data structs from JSON maps
  defp reconstruct_data(nil), do: nil
  defp reconstruct_data(map) when is_map(map), do: SerializableStruct.decode(map)
  defp reconstruct_data(data), do: data
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
        data: data_value
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
  alias Freyja.Run.SerializableResult

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
      value:
        map["value"]
        |> SerializableResult.from_json()
        |> SerializableResult.unwrap()
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
        value: Freyja.Run.SerializableResult.wrap(value.value)
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

  defstruct stack: [], queue: [], allow_divergence?: false

  @type t :: %__MODULE__{
          stack: list(StepLogEntry.t()),
          queue: list(StepLogEntry.t()),
          allow_divergence?: boolean()
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
    combined = Enum.reverse(log.stack) ++ log.queue

    # When allow_divergence? is true, drop incomplete entries from the queue.
    # These are stale entries from a failed run that won't happen in the rerun.
    # This is safe because prepare_for_retrace is NOT called on suspend/resume
    # (only on finalize), so we won't accidentally drop entries we need to replay.
    filtered =
      if log.allow_divergence? do
        Enum.filter(combined, & &1.completed?)
      else
        combined
      end

    %__MODULE__{
      log
      | stack: [],
        queue: Enum.map(filtered, &StepLogEntry.prepare_for_retrace/1)
    }
  end

  @doc """
  Reconstruct Log from decoded JSON map.
  """
  def from_json(map) when is_map(map) do
    %__MODULE__{
      stack: Enum.map(map["stack"] || [], &StepLogEntry.from_json/1),
      queue: Enum.map(map["queue"] || [], &StepLogEntry.from_json/1),
      allow_divergence?: map["allow_divergence?"] || false
    }
  end

  @doc """
  Create a log for resuming from an error.
  Allows divergence at the final log entry, enabling debugging scenarios where
  the code has been fixed and the error no longer occurs.
  """
  def for_error_resume(log) do
    %{log | allow_divergence?: true}
  end
end

defimpl Jason.Encoder, for: Freyja.Effects.EffectLogger.Log do
  def encode(value, opts) do
    Jason.Encode.map(
      %{
        stack: value.stack,
        queue: value.queue,
        allow_divergence?: value.allow_divergence?
      },
      opts
    )
  end
end
