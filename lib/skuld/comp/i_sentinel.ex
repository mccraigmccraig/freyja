defprotocol Skuld.Comp.ISentinel do
  @moduledoc """
  Protocol for handling sentinel values in run/run! and generic sentinel inspection.

  Sentinels are control flow values (Suspend, Throw, etc.) that bypass normal
  computation flow. This protocol allows generic handling without coupling to
  specific sentinel types.
  """
  @fallback_to_any true

  @doc "Complete a computation result - invoke leave_scope or bypass for sentinels"
  @spec run(t, Skuld.Comp.Types.env()) :: {Skuld.Comp.Types.result(), Skuld.Comp.Types.env()}
  def run(result, env)

  @doc "Extract value or raise for sentinel types"
  @spec run!(t) :: term()
  def run!(value)

  @doc "Is this a sentinel value? Returns false for plain values."
  @spec sentinel?(t) :: boolean()
  def sentinel?(value)

  @doc "Get the resume function if this sentinel is resumable, nil otherwise."
  @spec get_resume(t) :: (term() -> {term(), Skuld.Comp.Types.env()}) | nil
  def get_resume(sentinel)

  @doc "Return a new sentinel with the resume function replaced. Returns unchanged if not resumable."
  @spec with_resume(t, (term() -> {term(), Skuld.Comp.Types.env()})) :: t
  def with_resume(sentinel, new_resume)

  @doc "Get the serializable payload (struct fields minus :resume). Used for logging/serialization."
  @spec serializable_payload(t) :: map()
  def serializable_payload(sentinel)
end

defimpl Skuld.Comp.ISentinel, for: Any do
  def run(result, env), do: env.leave_scope.(result, env)
  def run!(value), do: value
  def sentinel?(_value), do: false
  def get_resume(_value), do: nil
  def with_resume(value, _new_resume), do: value
  def serializable_payload(_value), do: %{}
end
