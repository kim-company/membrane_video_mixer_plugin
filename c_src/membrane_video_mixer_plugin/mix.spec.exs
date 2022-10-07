module(RawVideo.Mixer.Native)

state_type("State")

interface([NIF])

spec(
  init(
    width :: [int],
    height :: [int],
    pixel_format :: [atom],
    filter :: string,
    out_width :: int,
    out_height :: int,
    out_format :: atom
  ) ::
    {:ok :: label, state} | {:error :: label, reason :: atom()}
)

spec(
  mix(buffers :: [payload], state) ::
    {:ok :: label, buffer :: payload} | {:error :: label, reason :: atom()}
)
