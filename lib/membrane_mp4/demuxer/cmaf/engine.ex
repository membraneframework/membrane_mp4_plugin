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
        {[], %{engine | pending_emsg: emsg_to_metadata(box.fields)}}

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

    emsg_metadata =
      resolve_emsg_metadata(engine.pending_emsg, this_mdat_samples, engine.last_timescales)

    samples =
      Enum.map(this_mdat_samples, fn sample ->
        timescale = engine.last_timescales[sample.track_id]

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

        %Sample{
          track_id: sample.track_id,
          payload: payload,
          pts: pts,
          dts: dts,
          metadata: emsg_metadata
        }
      end)

    {samples, %{engine | samples_info: rest_of_samples_info}}
  end

  defp reject_unsupported_tracks_info(tracks_info) do
    Map.reject(tracks_info, fn {_track_id, track_format} -> track_format == nil end)
  end

  # version 0: pts is relative to segment's base_media_decode_time — resolved later in read_mdat
  defp emsg_to_metadata(%{
         presentation_time_delta: delta,
         timescale: timescale,
         message_data: data
       }) do
    %{emsg_pts: {:delta, delta, timescale}, emsg_message_data: data}
  end

  # version 1: pts is absolute
  defp emsg_to_metadata(%{presentation_time: pts, timescale: timescale, message_data: data}) do
    %{emsg_pts: {:absolute, div(pts * 1000, timescale)}, emsg_message_data: data}
  end

  defp resolve_emsg_metadata(nil, _samples, _timescales), do: %{}

  defp resolve_emsg_metadata(
         %{emsg_pts: {:absolute, pts_ms}, emsg_message_data: data},
         _samples,
         _timescales
       ) do
    %{emsg_pts_ms: pts_ms, emsg_message_data: data}
  end

  # the emsg_pts is resolved relatively to the timestamp of the first sample
  # from the next moof box
  defp resolve_emsg_metadata(
         %{emsg_pts: {:delta, delta, emsg_timescale}, emsg_message_data: data},
         [first | _rest],
         timescales
       ) do
    {:ok, track_timescale} = Map.fetch(timescales, first.track_id)
    base_dts_ms = div(first.ts * 1000, track_timescale)
    %{emsg_pts_ms: base_dts_ms + div(delta * 1000, emsg_timescale), emsg_message_data: data}
  end
end
