defmodule Freyja.Run.RunBuilder do
  @moduledoc """
  Builder for constructing effect interpretation pipelines.

  Provides a pipe-friendly API for composing effect handlers and algebras:

      computation
      |> State.Handler.run(0)
      |> Writer.Handler.run([])
      |> Run.eval()

  The builder handles all complexity:
  - Detects whether input is computation or existing builder
  - Detects whether modules are algebras or handlers
  - Applies default initial states
  - Maintains separate queues for algebras and handlers

  ## Usage

      # Freer computation
      result = con do
        x <- State.get()
        return(x + 1)
      end
      |> State.Handler.run(5)
      |> Run.eval()

      # Hefty computation with algebras and handlers
      outcome = hefty do
        result <- Catch.catch_hefty(...)
        return(result)
      end
      |> Catch.Algebra.run()
      |> Lift.Algebra.run()
      |> State.Handler.run(0)
      |> Throw.Handler.run()
      |> Run.run()
  """

  alias Freyja.Freer
  alias Freyja.Hefty

  defstruct computation: nil,
            algebras: [],
            handlers: [],
            computation_type: nil

  @type computation_type :: :freer | :hefty
  @type t :: %__MODULE__{
          computation: Freer.t() | Hefty.t(),
          algebras: [module],
          handlers: [{module, any}],
          computation_type: computation_type | nil
        }

  @doc """
  Add a handler or algebra to the builder.

  This is the main entry point called by all handler/algebra `run` functions.

  Automatically detects:
  - Whether input is a computation (creates new builder) or existing builder
  - Whether module is an Algebra, Handler, or both
  - Default initial state if not provided

  ## Examples

      # Start new builder from computation
      builder = RunBuilder.add(computation, State.Handler, 0)

      # Add to existing builder
      builder = RunBuilder.add(builder, Writer.Handler, [])

      # Use default state (if handler provides it)
      builder = RunBuilder.add(builder, Throw.Handler)
  """
  @spec add(Freer.t() | Hefty.t() | t(), module, any) :: t()
  def add(computation_or_builder, module, initial_state \\ :__default__)

  # Case 1: Adding to existing builder
  def add(%__MODULE__{} = builder, module, initial_state) do
    case detect_module_type(module) do
      :algebra ->
        add_algebra(builder, module)

      :handler ->
        state =
          if initial_state == :__default__, do: get_default_state(module), else: initial_state

        add_handler(builder, module, state)

      :both ->
        # Module implements both Algebra and Handler!
        # Add to both queues
        state =
          if initial_state == :__default__, do: get_default_state(module), else: initial_state

        builder
        |> add_algebra(module)
        |> add_handler(module, state)

      :neither ->
        raise ArgumentError,
              "#{inspect(module)} implements neither Hefty.Algebra nor Freer.EffectHandler behavior"
    end
  end

  # Case 2: Starting new builder from computation
  def add(computation, module, initial_state) do
    builder = new(computation)
    add(builder, module, initial_state)
  end

  # Private functions

  defp new(computation) do
    {type, converted_computation} = detect_and_convert_computation(computation)

    %__MODULE__{
      computation: converted_computation,
      computation_type: type
    }
  end

  defp detect_and_convert_computation(computation) do
    case computation do
      %Freyja.Freer.Pure{} ->
        {:freer, computation}

      %Freyja.Freer.Impure{} ->
        {:freer, computation}

      %Freyja.Hefty.Pure{} ->
        {:hefty, computation}

      %Freyja.Hefty.Impure{} ->
        {:hefty, computation}

      _ ->
        # Try auto-lifting via protocols
        # Try ISendable first (more common for first-order effects)
        try_protocol_conversion(computation)
    end
  end

  defp try_protocol_conversion(computation) do
    # Try ISendable first (for first-order effects - more common)
    try do
      freer = Freyja.Freer.Sig.ISendable.send(computation)
      {:freer, freer}
    rescue
      _e in [Protocol.UndefinedError, ArgumentError] ->
        # Try IHeftySendable (for higher-order effects)
        try do
          hefty = Freyja.Hefty.Sig.IHeftySendable.send_to_hefty(computation)
          {:hefty, hefty}
        rescue
          _e2 in [Protocol.UndefinedError, ArgumentError] ->
            # Neither protocol works - provide a clear error message
            raise ArgumentError,
                  "Cannot detect computation type for: #{inspect(computation)}. " <>
                    "Value must be a Freer/Hefty computation or implement ISendable/IHeftySendable protocol."
        end
    end
  end

  defp detect_module_type(module) do
    Code.ensure_loaded(module)

    is_algebra =
      function_exported?(module, :elaborate, 4) and
        function_exported?(module, :handles?, 1)

    is_handler =
      function_exported?(module, :handles?, 2) and
        function_exported?(module, :interpret, 4)

    case {is_algebra, is_handler} do
      {true, true} -> :both
      {true, false} -> :algebra
      {false, true} -> :handler
      {false, false} -> :neither
    end
  end

  defp get_default_state(module) do
    if function_exported?(module, :default_initial_state, 0) do
      module.default_initial_state()
    else
      nil
    end
  end

  defp add_algebra(%__MODULE__{} = builder, algebra_module) do
    %{builder | algebras: builder.algebras ++ [algebra_module]}
  end

  defp add_handler(%__MODULE__{} = builder, handler_module, state) do
    %{builder | handlers: builder.handlers ++ [{handler_module, state}]}
  end
end
