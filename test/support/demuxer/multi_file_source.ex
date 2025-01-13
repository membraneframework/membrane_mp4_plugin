defmodule Membrane.MP4.Demuxer.MultiFileSource do
  @moduledoc false
  use Membrane.Source

  def_output_pad :output, accepted_format: _any, flow_control: :manual, demand_unit: :bytes

  def_options paths: [spec: [Path.t()]]

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{paths: opts.paths, binary: nil}}
  end

  @impl true
  def handle_setup(_ctx, state) do
    binary = Enum.map(state.paths, &File.read!/1) |> Enum.join()
    {[], %{state | binary: binary}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, %Membrane.RemoteStream{type: :bytestream}}], state}
  end

  @impl true
  def handle_demand(:output, demand_size, :bytes, ctx, state) do
    case state.binary do
      <<first::binary-size(demand_size), rest::binary>> ->
        {[buffer: {:output, %Membrane.Buffer{payload: first}}], %{state | binary: rest}}

      other ->
        final_buffers =
          if other != <<>>, do: [buffer: {:output, %Membrane.Buffer{payload: other}}], else: []

        maybe_eos = if not ctx.pads.output.end_of_stream?, do: [end_of_stream: :output], else: []
        {final_buffers ++ maybe_eos, %{state | binary: <<>>}}
    end
  end
end
