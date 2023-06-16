defmodule LogicElixir.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    children = [
      %{
        id: VarBuilder,
        # start: {Agent, :start_link, [fn -> 0 end, [name: VarBuilder]]}
        start: {VarBuilder, :start_link, []}
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end