defmodule Skuld.Effects.EffectLogger.LogEntry do
  @moduledoc """
  Structs representing different types of effect log entries.

  ## Entry Types

  - `Completed` - Effect completed synchronously with a result
  - `Thrown` - Effect threw an error (terminal)
  - `Started` - Suspending effect began execution
  - `Suspended` - Effect yielded/suspended with a value
  - `Resumed` - Suspended effect was resumed with input
  - `Finished` - Suspending effect completed after resume(s)

  ## Common Fields

  All entries have:
  - `:id` - Unique identifier for the effect invocation
  - `:timestamp` - When this event occurred

  Effect-identifying entries (`Completed`, `Thrown`, `Started`) also have:
  - `:effect` - The effect signature (module)
  - `:args` - The effect operation struct
  """

  defmodule Completed do
    @moduledoc "Simple effect completed synchronously"
    @enforce_keys [:id, :effect, :args, :result, :timestamp]
    defstruct [:id, :effect, :args, :result, :timestamp]

    @type t :: %__MODULE__{
            id: term(),
            effect: atom(),
            args: term(),
            result: term(),
            timestamp: DateTime.t()
          }
  end

  defmodule Thrown do
    @moduledoc "Effect threw an error (terminal sentinel)"
    @enforce_keys [:id, :effect, :args, :error, :timestamp]
    defstruct [:id, :effect, :args, :error, :timestamp]

    @type t :: %__MODULE__{
            id: term(),
            effect: atom(),
            args: term(),
            error: term(),
            timestamp: DateTime.t()
          }
  end

  defmodule Started do
    @moduledoc "Suspending effect started execution"
    @enforce_keys [:id, :effect, :args, :timestamp]
    defstruct [:id, :effect, :args, :timestamp]

    @type t :: %__MODULE__{
            id: term(),
            effect: atom(),
            args: term(),
            timestamp: DateTime.t()
          }
  end

  defmodule Suspended do
    @moduledoc "Effect suspended/yielded a value"
    @enforce_keys [:id, :timestamp]
    defstruct [:id, :yielded, :timestamp]

    @type t :: %__MODULE__{
            id: term(),
            yielded: term(),
            timestamp: DateTime.t()
          }
  end

  defmodule Resumed do
    @moduledoc "Suspended effect was resumed with input"
    @enforce_keys [:id, :input, :timestamp]
    defstruct [:id, :input, :timestamp]

    @type t :: %__MODULE__{
            id: term(),
            input: term(),
            timestamp: DateTime.t()
          }
  end

  defmodule Finished do
    @moduledoc "Suspending effect completed after resume(s)"
    @enforce_keys [:id, :result, :timestamp]
    defstruct [:id, :result, :timestamp]

    @type t :: %__MODULE__{
            id: term(),
            result: term(),
            timestamp: DateTime.t()
          }
  end

  @type t :: Completed.t() | Thrown.t() | Started.t() | Suspended.t() | Resumed.t() | Finished.t()
end
