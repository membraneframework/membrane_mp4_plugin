defmodule Membrane.MP4.Demuxer.CMAF.Engine do
  use Bunch.Access

  alias Membrane.MP4.Container
  alias Membrane.MP4.Demuxer.CMAF.SamplesInfo

  defmodule Sample do
    @moduledoc false
    @enforce_keys [:track_id, :payload, :pts, :dts]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            track_id: integer(),
            payload: binary(),
            pts: integer(),
            dts: integer()
          }
  end

  defstruct [
    :samples_to_pop,
    :unprocessed_boxes,
    :unprocessed_binary,
    :samples_info,
    :fsm_state,
    :last_timescales,
    :how_many_segment_bytes_read,
    :tracks_info
  ]

  @opaque t() :: %__MODULE__{}

  @spec new() :: t()
  def new() do
    %__MODULE__{
      samples_to_pop: [],
      unprocessed_boxes: [],
      unprocessed_binary: <<>>,
      samples_info: nil,
      fsm_state: :reading_cmaf_header,
      last_timescales: %{},
      how_many_segment_bytes_read: 0,
      tracks_info: nil
    }
  end

  @spec feed!(t(), binary()) :: t()
  def feed!(engine, data) do
    {new_boxes, rest} = Container.parse!(engine.unprocessed_binary <> data)

    {samples_to_pop, engine} =
      %{
        engine
        | unprocessed_boxes: engine.unprocessed_boxes ++ new_boxes,
          unprocessed_binary: rest
      }
      |> prepare_samples_to_pop()

    %{engine | samples_to_pop: engine.samples_to_pop ++ samples_to_pop}
  end

  @spec get_tracks_info(t()) :: {:ok, %{integer() => struct()}} | {:error, term()}
  def get_tracks_info(engine) do
    case engine.tracks_info do
      nil -> {:error, :not_available_yet}
      tracks_info -> {:ok, tracks_info}
    end
  end

  @spec pop_samples(t()) :: {:ok, [Sample.t()], t()}
  def pop_samples(engine) do
    {:ok, engine.samples_to_pop, %{engine | samples_to_pop: []}}
  end

  defp prepare_samples_to_pop(%{unprocessed_boxes: []} = engine) do
    {[], engine}
  end

  defp prepare_samples_to_pop(engine) do
    [{first_box_name, first_box} | rest_of_boxes] = engine.unprocessed_boxes
    {first_box_samples, engine} = handle_box(first_box_name, first_box, engine)

    {samples, engine} =
      prepare_samples_to_pop(%{engine | unprocessed_boxes: rest_of_boxes})

    {first_box_samples ++ samples, engine}
  end

  defp handle_box(box_name, box, %{fsm_state: :reading_cmaf_header} = engine) do
    case box_name do
      :ftyp ->
        {[], engine}

      :free ->
        {[], engine}

      :moov ->
        tracks_info =
          box
          |> SamplesInfo.read_moov()
          |> reject_unsupported_tracks_info()

        engine = %{
          engine
          | fsm_state: :reading_fragment_header,
            tracks_info: tracks_info
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

        new_fsm_state =
          if engine.samples_info == [],
            do: :reading_fragment_header,
            else: :reading_fragment_data

        {samples, %{engine | fsm_state: new_fsm_state}}

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
      this_mdat_samples
      |> Enum.map(fn sample ->
        payload =
          mdat_box.content
          |> :erlang.binary_part(sample.offset - engine.how_many_segment_bytes_read, sample.size)

        dts =
          Ratio.new(sample.ts, engine.last_timescales[sample.track_id])
          |> Ratio.mult(1000)
          |> Ratio.floor()

        pts =
          Ratio.new(
            sample.ts + sample.composition_offset,
            engine.last_timescales[sample.track_id]
          )
          |> Ratio.mult(1000)
          |> Ratio.floor()

        %Sample{track_id: sample.track_id, payload: payload, pts: pts, dts: dts}
      end)

    {samples, %{engine | samples_info: rest_of_samples_info}}
  end

  defp reject_unsupported_tracks_info(tracks_info) do
    Map.reject(tracks_info, fn {_track_id, track_format} -> track_format == nil end)
  end
end
