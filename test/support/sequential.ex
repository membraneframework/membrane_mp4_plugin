defmodule Membrane.MP4.Support.Sequential do
  @moduledoc false

  # An element that forwards buffers on primary_in pad and
  # suspends passing any buffers from secondary_in pad until
  # primary_in pad receives end_of_stream event.

  use Membrane.Filter

  def_input_pad :primary_in,
    demand_unit: :buffers,
    caps: :any

  def_input_pad :secondary_in,
    demand_unit: :buffers,
    caps: :any

  def_output_pad :primary_out, caps: :any

  def_output_pad :secondary_out, caps: :any

  @impl true
  def handle_init(_options) do
    {:ok, %{primary_eos?: false, secondary_eos?: false, buffers: []}}
  end

  @impl true
  def handle_caps(:primary_in, caps, _ctx, state) do
    {{:ok, caps: {:primary_out, caps}}, state}
  end

  @impl true
  def handle_caps(:secondary_in, caps, _ctx, state) do
    {{:ok, caps: {:secondary_out, caps}}, state}
  end

  @impl true
  def handle_demand(:primary_out, size, :buffers, _ctx, state) do
    {{:ok, demand: {:primary_in, size}}, state}
  end

  @impl true
  def handle_demand(:secondary_out, size, :buffers, _ctx, state) do
    {{:ok, demand: {:secondary_in, size}}, state}
  end

  @impl true
  def handle_process(:primary_in, buffer, _ctx, state) do
    {{:ok, buffer: {:primary_out, buffer}}, state}
  end

  @impl true
  def handle_process(:secondary_in, buffer, _ctx, %{primary_eos?: false} = state) do
    state = Map.update!(state, :buffers, &[buffer | &1])

    {:ok, state}
  end

  @impl true
  def handle_process(:secondary_in, buffer, _ctx, state) do
    {{:ok, buffer: {:secondary_out, buffer}}, state}
  end

  @impl true
  def handle_end_of_stream(:primary_in, _ctx, state) do
    state = Map.put(state, :primary_eos?, true)

    maybe_secondary_eos =
      if state.secondary_eos? do
        [end_of_stream: :secondary_out]
      else
        []
      end

    {{:ok,
      [buffer: {:secondary_out, Enum.reverse(state.buffers)}, end_of_stream: :primary_out] ++
        maybe_secondary_eos}, state}
  end

  @impl true
  def handle_end_of_stream(:secondary_in, _ctx, state) do
    state = Map.put(state, :secondary_eos?, true)

    maybe_secondary_eos =
      if state.primary_eos? do
        [end_of_stream: :secondary_out]
      else
        []
      end

    {{:ok, maybe_secondary_eos}, state}
  end
end
