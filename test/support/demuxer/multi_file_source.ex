  defmodule Membrane.MP4.Demuxer.MultiFileSource do
    @moduledoc false
    use Membrane.Source 
  
    def_output_pad :output, accepted_format: _any, flow_control: :push

    def_options paths: [spec: [Path.t()]]
  
    @impl true
    def handle_init(_ctx, opts) do
      {[], %{paths: opts.paths}}  
    end

    @impl true
    def handle_playing(_ctx, state) do
      {[stream_format: {:output, %Membrane.RemoteStream{type: :bytestream}}, buffer: {:output, read_files(state.paths)}, end_of_stream: :output], state}
    end

    defp read_files(files) do
      Enum.map(files, &File.read!/1)          
      |> Enum.map(&%Membrane.Buffer{payload: &1})
    end
 end
