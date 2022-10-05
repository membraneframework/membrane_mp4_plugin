defmodule Membrane.MP4.Demuxer.ISOM.SampleHelper do
  @moduledoc false
  alias Membrane.Buffer

  @enforce_keys [:chunk_offsets, :sample_sizes, :sample_to_chunk, :sample_deltas, :samples]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          chunk_offsets: [%{(offset :: non_neg_integer()) => track_id :: pos_integer()}],
          sample_sizes: [%{entry_size: pos_integer(), track_id: pos_integer()}],
          sample_to_chunk: [%{}],
          samples: [
            %{
              size: pos_integer(),
              chunk_id: pos_integer(),
              sample_delta: pos_integer(),
              track_id: pos_integer()
            }
          ]
        }

  @spec get_samples(t, data :: binary()) ::
          {[{Buffer.t(), track_id :: pos_integer()}], rest :: binary, t}
  def get_samples(t, _data) do
    {[{%Buffer{payload: <<>>}, 1}], <<>>, t}
  end

  @spec get_sample_data(any) :: nil
  def get_sample_data(_moov) do
  end
end
