defmodule Freyja.Effects.EffectLogger.EffectLogEntry do
  @moduledoc """
  A single effect
  """
  defstruct sig: nil, data: nil, scoped_log: nil
  @type t :: %__MODULE__{sig: any, data: any, scoped_log: nil}

  def new(sig, data) do
    %__MODULE__{sig: sig, data: data}
  end

  def set_scoped_log(self, scoped_log) do
    Map.put(self, :scoped_log, scoped_log)
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

  def set_scoped_log(%__MODULE__{} = self, scoped_log) do
    case self.effects_queue do
      [%EffectLogEntry{} = int_log_entry | rest] ->
        %{
          self
          | effects_queue: [EffectLogEntry.set_scoped_log(int_log_entry, scoped_log) | rest]
        }

      _ ->
        raise ArgumentError,
          message:
            "unexpected scoped_log: #{inspect(self, pretty: true)}\n" <>
              "#{inspect(scoped_log, pretty: true)}"
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
end

# cf interceptor chains
defmodule Freyja.Effects.EffectLogger.Log do
  @moduledoc """
  A structured log of a whole computation
  """
  alias Freyja.Effects.EffectLogger.EffectLogEntry
  alias Freyja.Effects.EffectLogger.StepLogEntry
  alias Freyja.Freer.Impure

  defstruct stack: [], queue: []

  @type t :: %__MODULE__{
          stack: list(StepLogEntry.t()),
          queue: list(StepLogEntry.t())
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

      [%StepLogEntry{effects_queue: [_prev | _]} = le | _rest] ->
        StepLogEntry.push_effect(le, sig, data)
    end
  end

  @doc """
  set the scoped_log as the scoped_log of the current effect in the
  currently open step of the log - closes the step in the process
  because a scoped cmputation always returns a value
  """
  def set_scoped_log(%__MODULE__{} = parent_log, %__MODULE__{} = scoped_log) do
    # we can actually ignore log, because it's set as the :parent on the
    # scoped_log - which is done so that we can fully recover from a suspend
    # or error in a nested/scoped effect with just the scoped_log
    case parent_log.queue do
      [%StepLogEntry{} = parent_steop_log_entry | rest] ->
        %{
          parent_log
          | queue: [
              StepLogEntry.set_scoped_log(
                parent_steop_log_entry,
                Map.put(scoped_log, :parent, nil)
              )
              | rest
            ]
        }

      _ ->
        raise ArgumentError,
          message:
            "unexpected scoped_log: #{inspect(scoped_log, pretty: true)}\n" <>
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
end
