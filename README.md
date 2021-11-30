# MPEG-4 container plugin for Membrane Framework

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_mp4_plugin.svg)](https://hex.pm/packages/membrane_mp4_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_mp4_plugin/)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_mp4_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_mp4_plugin)

This plugin provides utilities for MP4 container parsing and serialization along with elements for muxing the stream to MP4 or [CMAF](https://www.wowza.com/blog/what-is-cmaf).

## Installation
The package can be installed by adding `membrane_mp4_plugin` to your list of dependencies in `mix.exs`:

```elixir
defp deps do
[
    {:membrane_mp4_plugin, "~> 0.10.0"}
]
end
```

## Usage
### `Membrane.MP4.Muxer.ISOM`
For an example of muxing streams to a regular MP4 file, refer to 
[`examples/muxer_isom.exs`](examples/muxer_isom.exs).

To run the example, you can use the following command:
 ```bash
elixir examples/muxer_isom.exs
``` 

### `Membrane.MP4.Muxer.CMAF`
To use the output stream of the CMAF muxer, you need a sink that will dump it to a playlist in a proper format.

In `membrane_http_adaptive_stream_plugin` repository you can find [an example](https://github.com/membraneframework/membrane_http_adaptive_stream_plugin/blob/master/examples/hls_sink.exs) 
that uses the CMAF muxer to create an HTTP Live Streaming playlist.

## Updating tests

In case `out_*` reference files in `test/fixtures/cmaf` change, `out_playlist.m3u8` and its dependent playlists should be updated and checked if they are still playable.
The current files have been checked with ffplay (FFmpeg) and Safari.

## Copyright and License

Copyright 2019, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_mp4_plugin)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane_mp4_plugin)

Licensed under the [Apache License, Version 2.0](LICENSE)
