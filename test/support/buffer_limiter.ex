defmodule Membrane.MP4.BufferLimiter do
  @moduledoc """
  Filter responsible for collecting buffers as long as there is no pending
  release request.
  """
  use Membrane.Filter

  def_options parent: [
                spec: pid(),
                description: """
                Parent process that is responsible for
                unblocking buffers.
                """
              ],
              tag: [
                spec: any(),
                description: """
                Tag that will be sent to parent on element initialization.
                """
              ]

  def_input_pad :input,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: _any

  def_output_pad :output,
    accepted_format: _any,
    flow_control: :manual

  @spec release_buffers(pid(), pos_integer()) :: reference()
  def release_buffers(limiter, n) do
    ref = make_ref()
    send(limiter, {:release, ref, n})

    ref
  end

  @spec await_buffers_released(reference()) :: :ok
  def await_buffers_released(ref) do
    receive do
      {:released, ^ref} -> :ok
    after
      5_000 ->
        raise "Not released"
    end
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {[demand: {:input, size}], state}
  end

  @impl true
  def handle_init(_ctx, %__MODULE__{parent: parent, tag: tag}) do
    send(parent, {:buffer_limiter, tag, self()})

    {[], %{tag: tag, queue: Qex.new(), parent: parent, request_ref: nil, requested: 0}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    queue = Qex.push(state.queue, buffer)
    state = %{state | queue: queue}

    maybe_send_buffers(state)
  end

  defp maybe_send_buffers(state) when state.requested == 0 do
    {[], state}
  end

  defp maybe_send_buffers(state) do
    to_take = min(Enum.count(state.queue), state.requested)
    {to_send, to_keep} = Qex.split(state.queue, to_take)

    buffers =
      to_send
      |> Enum.into([])
      |> Enum.map(&{:buffer, {:output, &1}})

    state = %{state | queue: to_keep, requested: state.requested - Enum.count(buffers)}

    if state.requested == 0 and to_take > 0 do
      send(state.parent, {:released, state.request_ref})
    end

    {buffers, state}
  end

  @impl true
  def handle_info({:release, ref, n}, _ctx, state) do
    state = %{state | request_ref: ref, requested: state.requested + n}

    maybe_send_buffers(state)
  end
end
