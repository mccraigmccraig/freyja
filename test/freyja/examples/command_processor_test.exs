defmodule Freyja.Examples.CommandProcessorTest do
  use ExUnit.Case, async: true

  alias Freyja.Examples.CommandProcessor
  alias Freyja.Examples.CommandProcessor.Notifications
  alias Freyja.Examples.CommandProcessor.Storage
  alias Freyja.Run

  setup do
    builder = CommandProcessor.builder()

    {:ok, builder: builder}
  end

  test "processes a sequence of commands and stops", %{builder: builder} do
    outcome = Run.run(builder)
    assert {:suspend, :next_command, _} = outcome.result

    outcome =
      outcome
      |> run_resume(builder, %Storage.Query{table: :products, id: "sku-1"})
      |> run_resume(builder, %Storage.Change{table: :users, record: %{id: 1, name: "Ann"}})
      |> run_resume(builder, %Notifications.SendPush{user_id: 1, message: "hello!"})
      |> run_resume(builder, :stop)

    assert {:done, {:ok, :stopped}} = outcome.result

    storage_state = outcome.outputs[Storage.Handler]
    notifications_state = outcome.outputs[Notifications.Handler]

    assert Enum.reverse(storage_state.queries) == [%Storage.Query{table: :products, id: "sku-1"}]

    assert Enum.reverse(storage_state.changes) == [
             %Storage.Change{table: :users, record: %{id: 1, name: "Ann"}}
           ]

    assert Enum.reverse(notifications_state.pushes) == [
             %Notifications.SendPush{user_id: 1, message: "hello!"}
           ]
  end

  defp run_resume(outcome, builder, command), do: Run.resume(builder, outcome, command)
end
