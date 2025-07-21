defmodule Membrane.MP4.Demuxer.ISOM.Engine do
  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.ISOM.SamplesInfo

  @max_header_size 16

  @enforce_keys [:provide_data_cb]
  defstruct @enforce_keys ++
              [
                cursor: 0,
                box_positions: %{},
                boxes: %{},
                samples_info: nil,
                tracks: %{}
              ]

  defp default_provide_data_cb(start, size) do
    f = File.open!("test/fixtures/isom/ref_two_tracks.mp4")
    :file.position(f, start)
    content = IO.binread(f, size)
    File.close(f)
    content
  end

  def new(provide_data_cb \\ &default_provide_data_cb/2) do
    %__MODULE__{provide_data_cb: provide_data_cb}
    |> find_box(:moov)
    |> read_box(:moov)
    |> find_box(:mdat)
    |> resolve_samples()
    |> initialize_tracks()
  end

  def get_tracks_info(state) do
    state.samples_info.sample_tables
  end

  def read_sample(state, track_id) do
    pos = state.tracks[track_id].pos
    sample = state.tracks[track_id].samples |> Enum.at(pos)

    case sample do
      nil ->
        :end_of_stream

      sample ->
        size = sample.size
        offset = sample.sample_offset
        data = state.provide_data_cb.(offset, size)

        dts =
          state.tracks[track_id].samples
          |> Enum.slice(0..pos)
          |> Enum.drop(-1)
          |> Enum.map(& &1.sample_delta)
          |> Enum.sum()

        pts = dts + sample.sample_composition_offset

        state = update_in(state.tracks[track_id].pos, &(&1 + 1))
        pts_seconds = pts / state.samples_info.timescales[track_id]
        dts_seconds = dts / state.samples_info.timescales[track_id]

        {:ok, %{payload: data, pts: pts_seconds, dts: dts_seconds}, state}
    end
  end

  def seek_in_samples(state, track_id, timestamp_seconds) do
    timestamp_in_native_unit = timestamp_seconds * state.samples_info.timescales[track_id]

    new_pos =
      state.tracks[track_id].samples
      |> Enum.map_reduce(0, &{{&1, &2}, &1.sample_delta + &2})
      |> elem(0)
      |> Enum.take_while(fn {_sample, cumulative_duration} ->
        cumulative_duration < timestamp_in_native_unit
      end)
      |> length()

    put_in(state.tracks[track_id].pos, new_pos)
  end

  defp find_box(state, box_name) do
    data = state.provide_data_cb.(state.cursor, @max_header_size)
    {:ok, header, _rest} = Container.Header.parse(data)

    if header.name == box_name do
      state =
        update_in(
          state.box_positions,
          &Map.put(&1, box_name, {state.cursor, header.header_size, header.content_size})
        )

      %{state | cursor: 0}
    else
      update_in(state.cursor, &(&1 + header.header_size + header.content_size))
      |> find_box(box_name)
    end
  end

  defp read_box(state, box_name) do
    {box_start, box_header_size, box_content_size} = Map.get(state.box_positions, box_name)

    {[{box_name, box}], _rest} =
      state.provide_data_cb.(box_start, box_header_size + box_content_size) |> Container.parse!()

    update_in(state.boxes, &Map.put(&1, box_name, box))
  end

  defp resolve_samples(state) do
    {mdat_start, mdat_header_size, _mdat_content_size} = Map.get(state.box_positions, :mdat)

    samples_info =
      SamplesInfo.get_samples_info(
        state.boxes[:moov],
        mdat_start + mdat_header_size
      )

    %{state | samples_info: samples_info}
  end

  defp initialize_tracks(state) do
    tracks =
      Map.keys(state.samples_info.sample_tables)
      |> Enum.map(fn id ->
        samples = Enum.filter(state.samples_info.samples, &(&1.track_id == id))
        {id, %{pos: 0, samples: samples}}
      end)
      |> Enum.into(%{})

    %{state | tracks: tracks}
  end
end
