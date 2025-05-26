defmodule Membrane.MP4.Demuxer.CMAF do
  @moduledoc """
  A Membrane Filter capable of demuxing streams packed in CMAF container.

  Uses under the hood `Membrane.MP4.Demuxer.CMAF.Engine`.
  """
  use Membrane.Filter

  alias Membrane.{MP4, RemoteStream}

  def_input_pad :input,
    accepted_format:
      %RemoteStream{type: :bytestream, content_format: content_format}
      when content_format in [nil, MP4],
    flow_control: :auto

  def_output_pad :output,
    accepted_format:
      any_of(
        %Membrane.AAC{config: {:esds, _esds}},
        %Membrane.H264{
          stream_structure: {_avc, _dcr},
          alignment: :au
        },
        %Membrane.H265{
          stream_structure: {_hevc, _dcr},
          alignment: :au
        },
        %Membrane.Opus{self_delimiting?: false}
      ),
    availability: :on_request,
    options: [
      kind: [
        spec: :video | :audio | nil,
        default: nil,
        description: """
        Specifies, what kind of data can be handled by a pad.
        """
      ]
    ]

  @typedoc """
  Notification sent when the tracks are identified in the MP4.

  Upon receiving the notification, `Pad.ref(:output, track_id)` pads should be linked
  for all the `track_id` in the list.
  The `content` field contains the stream format which is contained in the track.
  """
  @type new_tracks_t() ::
          {:new_tracks, [{track_id :: integer(), content :: struct()}]}

  @impl true
  def handle_init(_ctx, _options) do
    state = %{
      engine: __MODULE__.Engine.new(),
      all_pads_connected?: false,
      track_to_pad_map: nil,
      new_tracks_sent?: false,
      stream_format_sent?: false
    }

    {[], state}
  end

  @impl true
  def handle_pad_added(_pad, ctx, state) do
    cond do
      state.all_pads_connected? ->
        raise "All pads have corresponding track already connected"

      ctx.playback == :playing and not state.new_tracks_sent? ->
        raise """
        Pads can be linked either before #{inspect(__MODULE__)} enters :playing playback or after it \
        sends {:new_tracks, ...} notification
        """

      true ->
        :ok
    end

    state = %{state | all_pads_connected?: all_pads_connected?(ctx, state)}

    if state.all_pads_connected? do
      {maybe_stream_actions, state} = maybe_stream(ctx, state)
      {maybe_stream_actions ++ [resume_auto_demand: :input], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(:input, buffer, ctx, state) do
    state =
      Map.update!(state, :engine, fn engine ->
        __MODULE__.Engine.feed!(engine, buffer.payload)
      end)

    {maybe_notification, state} = maybe_new_tracks(ctx, state)
    maybe_pause = maybe_pause_auto_demand(ctx, state)
    {maybe_stream_actions, state} = maybe_stream(ctx, state)

    {maybe_notification ++ maybe_pause ++ maybe_stream_actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    maybe_stream(ctx, state)
  end

  defp maybe_new_tracks(ctx, state) do
    with %{new_tracks_sent?: false} <- state,
         {:ok, tracks_info} <- __MODULE__.Engine.get_tracks_info(state.engine) do
      state = %{state | all_pads_connected?: all_pads_connected?(ctx, state)}
      state = match_tracks_with_pads(ctx, state)

      notification = [notify_parent: {:new_tracks, Map.to_list(tracks_info)}]
      {notification, %{state | new_tracks_sent?: true}}
    else
      _other -> {[], state}
    end
  end

  defp maybe_pause_auto_demand(ctx, state) do
    if state.new_tracks_sent? and not state.all_pads_connected? and
         not ctx.pads.input.auto_demand_paused? do
      [pause_auto_demand: :input]
    else
      []
    end
  end

  defp maybe_stream(_ctx, %{all_pads_connected?: false} = state) do
    {[], state}
  end

  defp maybe_stream(ctx, state) do
    maybe_stream_formats =
      if state.stream_format_sent?,
        do: [],
        else: get_stream_formats(state)

    state = %{state | stream_format_sent?: true}

    {buffers, state} = get_buffers(state)

    maybe_end_of_streams =
      if ctx.pads.input.end_of_stream?,
        do: get_end_of_streams(ctx),
        else: []

    {maybe_stream_formats ++ buffers ++ maybe_end_of_streams, state}
  end

  defp all_pads_connected?(ctx, state) do
    with {:ok, tracks_info} <- __MODULE__.Engine.get_tracks_info(state.engine) do
      output_pads_number =
        ctx.pads |> Enum.count(fn {_ref, data} -> data.direction == :output end)

      output_pads_number == map_size(tracks_info)
    else
      {:error, :not_available_yet} -> false
    end
  end

  defp match_tracks_with_pads(ctx, state) do
    output_pads_data =
      Enum.flat_map(ctx.pads, fn
        {Pad.ref(:output, _id), pad_data} -> [pad_data]
        _input_pad_entry -> []
      end)

    {:ok, tracks_info} = __MODULE__.Engine.get_tracks_info(state.engine)

    if length(output_pads_data) not in [0, map_size(tracks_info)] do
      raise_pads_not_matching_tracks_error!(ctx, tracks_info)
    end

    track_to_pad_map =
      case output_pads_data do
        [] ->
          tracks_info
          |> Map.new(fn {track_id, _format} ->
            {track_id, Pad.ref(:output, track_id)}
          end)

        # handles also the case when we have only one pad with kind: nil
        [pad_data] ->
          [{track_id, stream_format}] = tracks_info |> Map.to_list()

          if pad_data.options.kind not in [nil, format_to_kind(stream_format)] do
            raise_pads_not_matching_tracks_error!(ctx, tracks_info)
          end

          %{track_id => pad_data.ref}

        _many ->
          kind_to_pads =
            output_pads_data
            |> Enum.group_by(& &1.options.kind)

          kind_to_tracks =
            tracks_info
            |> Enum.group_by(fn {_id, format} -> format_to_kind(format) end)

          if map_size(kind_to_pads) != map_size(kind_to_tracks) do
            raise_pads_not_matching_tracks_error!(ctx, tracks_info)
          end

          Enum.any?(kind_to_pads, fn {kind, pads} ->
            length(pads) != length(kind_to_tracks[kind])
          end)
          |> if do
            raise_pads_not_matching_tracks_error!(ctx, tracks_info)
          end

          kind_to_tracks
          |> Enum.flat_map(fn {kind, tracks} ->
            Enum.zip(tracks, kind_to_pads[kind])
          end)
          |> Map.new(fn {{track_id, _track_format}, pad_data} ->
            {track_id, pad_data.ref}
          end)
      end

    %{state | track_to_pad_map: track_to_pad_map}
  end

  defp format_to_kind(%Membrane.H264{}), do: :video
  defp format_to_kind(%Membrane.H265{}), do: :video
  defp format_to_kind(%Membrane.AAC{}), do: :audio
  defp format_to_kind(%Membrane.Opus{}), do: :audio

  @spec raise_pads_not_matching_tracks_error!(map(), [{any(), struct()}]) :: no_return()
  defp raise_pads_not_matching_tracks_error!(ctx, tracks_info) do
    pads_kinds =
      ctx.pads
      |> Enum.flat_map(fn
        {:input, _pad_data} -> []
        {_pad_ref, %{options: %{kind: kind}}} -> [kind]
      end)

    tracks_format = tracks_info |> Enum.map(fn {_id, format} -> format end)

    raise """
    Pads kinds don't match with tracks formats. Pads kinds are #{inspect(pads_kinds)}. \
    Tracks formats are #{inspect(tracks_format, pretty: true)}
    """
  end

  defp get_stream_formats(state) do
    with {:ok, tracks_info} <- __MODULE__.Engine.get_tracks_info(state.engine) do
      tracks_info
      |> Enum.map(fn {track_id, track_format} ->
        pad_ref = state.track_to_pad_map |> Map.fetch!(track_id)
        {:stream_format, {pad_ref, track_format}}
      end)
    else
      {:error, :not_available_yet} -> []
    end
  end

  defp get_buffers(state) do
    with {:ok, samples, engine} <- __MODULE__.Engine.pop_samples(state.engine) do
      buffers =
        Enum.map(samples, fn sample ->
          pad_ref = state.track_to_pad_map |> Map.fetch!(sample.track_id)

          buffer = %Membrane.Buffer{
            payload: sample.payload,
            pts: sample.pts |> Membrane.Time.milliseconds(),
            dts: sample.dts |> Membrane.Time.milliseconds()
          }

          {:buffer, {pad_ref, buffer}}
        end)

      {buffers, %{state | engine: engine}}
    else
      {:error, :not_available_yet} -> {[], state}
    end
  end

  defp get_end_of_streams(ctx) do
    ctx.pads
    |> Enum.flat_map(fn
      {Pad.ref(:output, _id) = pad_ref, _data} -> [end_of_stream: pad_ref]
      {:input, _data} -> []
    end)
  end
end
