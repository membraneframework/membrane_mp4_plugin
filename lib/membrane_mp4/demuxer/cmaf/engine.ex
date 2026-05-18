defmodule Membrane.MP4.Demuxer.CMAF.Engine do
  @moduledoc """
  A module capable of demuxing streams packed in CMAF container.

  It is used to demux streams in `Membrane.MP4.Demuxer.CMAF`.
  """
  use Bunch.Access

  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.CMAF.SamplesInfo
  alias Membrane.MP4.Demuxer.Sample

  defstruct [
    :samples_to_pop,
    :unprocessed_binary,
    :samples_info,
    :fsm_state,
    :last_timescales,
    :how_many_segment_bytes_read,
    :tracks_info,
    :pending_emsg
  ]

  @opaque t() :: %__MODULE__{}

  @spec new() :: t()
  def new() do
    %__MODULE__{
      samples_to_pop: [],
      unprocessed_binary: <<>>,
      samples_info: nil,
      fsm_state: :reading_cmaf_header,
      last_timescales: %{},
      how_many_segment_bytes_read: 0,
      tracks_info: nil,
      pending_emsg: nil
    }
  end

  @doc """
  This function feeds the demuxer engine with the binary data containing
  content of CMAF MP4 files.

  Then, demuxed stream samples can be retrieved using `pop_samples/1`.

  The function raises if the binary data is malformed.
  """
  @spec feed!(t(), binary()) :: t()
  def feed!(%__MODULE__{} = engine, data) do
    {parsed_boxes, rest} = Container.parse!(engine.unprocessed_binary <> data)
    engine = %{engine | unprocessed_binary: rest}

    {new_samples, engine} =
      parsed_boxes
      |> Enum.flat_map_reduce(engine, fn {box_name, box}, engine ->
        handle_box(box_name, box, engine)
      end)

    engine |> Map.update!(:samples_to_pop, &(&1 ++ new_samples))
  end

  @doc """
  Returns the tracks information that has been parsed from the CMAF stream.

  The tracks information is a map where keys are track IDs and values are
  stream format structs.

  If the tracks information is not available yet, it returns an error tuple
  `{:error, :not_available_yet}` and it means that engine has to be fed with
  more data before the tracks information can be retrieved.
  """

  @spec get_tracks_info(t()) ::
          {:ok, %{(track_id :: integer()) => stream_format :: struct()}} | {:error, term()}
  def get_tracks_info(%__MODULE__{} = engine) do
    case engine.tracks_info do
      nil -> {:error, :not_available_yet}
      tracks_info -> {:ok, tracks_info}
    end
  end

  @doc """
  Pops samples that have been demuxed from the CMAF stream privided in `feed!/2`.

  Returns a tuple with `:ok` and a list of samples, and the updated demuxer engine
  state.

  The samples are instances of `Membrane.MP4.Demuxer.Sample`.

  If no samples are available, it returns an empty list.
  """
  @spec pop_samples(t()) :: {:ok, [Sample.t()], t()}
  def pop_samples(%__MODULE__{} = engine) do
    {:ok, engine.samples_to_pop, %{engine | samples_to_pop: []}}
  end

  defp handle_box(box_name, box, %{fsm_state: :reading_cmaf_header} = engine) do
    case box_name do
      :ftyp ->
        {[], engine}

      :free ->
        {[], engine}

      :moov ->
        {tracks_info_raw, moov_timescales} = SamplesInfo.read_moov(box)
        tracks_info = reject_unsupported_tracks_info(tracks_info_raw)

        engine = %{
          engine
          | fsm_state: :reading_fragment_header,
            tracks_info: tracks_info,
            last_timescales: moov_timescales
        }

        {[], engine}

      _other ->
        raise """
        Demuxer entered unexpected state.
        Demuxer's finite state machine's state: #{inspect(engine.fsm_state)}
        Encountered box type: #{inspect(box_name)}
        """
    end
  end

  defp handle_box(box_name, box, %{fsm_state: :reading_fragment_header} = engine) do
    case box_name do
      :sidx ->
        engine =
          engine
          |> put_in([:last_timescales, box.fields.reference_id], box.fields.timescale)

        {[], engine}

      :styp ->
        {[], engine}

      :emsg ->
        {[], %{engine | pending_emsg: parse_emsg(box.content)}}

      :moof ->
        {[],
         %{
           engine
           | samples_info: SamplesInfo.get_samples_info(box),
             fsm_state: :reading_fragment_data,
             how_many_segment_bytes_read: box.size + box.header_size
         }}

      _other ->
        raise """
        Demuxer entered unexpected state.
        Demuxer's finite state machine's state: #{inspect(engine.fsm_state)}
        Encountered box type: #{inspect(box_name)}
        """
    end
  end

  defp handle_box(box_name, box, %{fsm_state: :reading_fragment_data} = engine) do
    case box_name do
      :mdat ->
        engine =
          engine
          |> Map.update!(:how_many_segment_bytes_read, &(&1 + box.header_size))

        {samples, engine} = read_mdat(box, engine)

        {new_fsm_state, new_pending_emsg} =
          if engine.samples_info == [],
            do: {:reading_fragment_header, nil},
            else: {:reading_fragment_data, engine.pending_emsg}

        {samples, %{engine | fsm_state: new_fsm_state, pending_emsg: new_pending_emsg}}

      _other ->
        raise """
        Demuxer entered unexpected state.
        Demuxer's finite state machine's state: #{inspect(engine.fsm_state)}
        Encountered box type: #{inspect(box_name)}
        """
    end
  end

  defp read_mdat(mdat_box, engine) do
    {this_mdat_samples, rest_of_samples_info} =
      Enum.split_while(
        engine.samples_info,
        &(&1.offset - engine.how_many_segment_bytes_read < byte_size(mdat_box.content))
      )

    samples =
      Enum.flat_map(this_mdat_samples, fn sample ->
        case Map.fetch(engine.last_timescales, sample.track_id) do
          {:ok, timescale} ->
            payload =
              mdat_box.content
              |> :erlang.binary_part(
                sample.offset - engine.how_many_segment_bytes_read,
                sample.size
              )

            dts =
              Ratio.new(sample.ts, timescale)
              |> Ratio.mult(1000)
              |> Ratio.floor()

            pts =
              Ratio.new(sample.ts + sample.composition_offset, timescale)
              |> Ratio.mult(1000)
              |> Ratio.floor()

            metadata =
              case engine.pending_emsg do
                nil -> %{}
                emsg -> emsg
              end

            [
              %Sample{
                track_id: sample.track_id,
                payload: payload,
                pts: pts,
                dts: dts,
                metadata: metadata
              }
            ]

          :error ->
            []
        end
      end)

    {samples, %{engine | samples_info: rest_of_samples_info}}
  end

  defp reject_unsupported_tracks_info(tracks_info) do
    Map.reject(tracks_info, fn {_track_id, track_format} -> track_format == nil end)
  end

  # emsg (ISO 23009-1 Event Message Box) arrives as a black box (not in MP4 schema).
  # Version 0 structure: version(1) + flags(3) + scheme_id_uri(str\0) + value(str\0)
  #                      + timescale(u32) + presentation_time_delta(u32)
  #                      + event_duration(u32) + id(u32) + message_data
  # Version 1 structure: same but presentation_time(u64) instead of presentation_time_delta(u32).
  defp parse_emsg(<<0::8, _flags::24, rest::binary>>) do
    with [_scheme_id_uri, after_scheme] <- :binary.split(rest, <<0>>),
         [_value, after_value] <- :binary.split(after_scheme, <<0>>),
         <<timescale::32, pts_delta::32, _duration::32, _id::32, message_data::binary>> <-
           after_value do
      pts_ms = div(pts_delta * 1000, timescale)
      %{emsg_pts_ms: pts_ms, emsg_message_data: message_data}
    else
      _ -> nil
    end
  end

  defp parse_emsg(<<1::8, _flags::24, rest::binary>>) do
    with [_scheme_id_uri, after_scheme] <- :binary.split(rest, <<0>>),
         [_value, after_value] <- :binary.split(after_scheme, <<0>>),
         <<timescale::32, pts::64, _duration::32, _id::32, message_data::binary>> <- after_value do
      pts_ms = div(pts * 1000, timescale)
      %{emsg_pts_ms: pts_ms, emsg_message_data: message_data}
    else
      _ -> nil
    end
  end

  defp parse_emsg(_content), do: nil
end
