import math

MODEL = "nvidia/nemotron-3.5-embed-1b"
DIM = 2048
COLUMN = "nemotron_35_1b_embedding"


def vector(client, text, kind):
    response = client.post(
        "https://integrate.api.nvidia.com/v1/embeddings",
        json={"model": MODEL, "input": [text], "input_type": kind,
              "encoding_format": "float", "truncate": "END"},
    )
    response.raise_for_status()
    values = response.json()["data"][0]["embedding"]
    if len(values) != DIM or not all(math.isfinite(x) for x in values):
        raise ValueError("Unexpected NVIDIA embedding")
    return "[" + ",".join(map(str, values)) + "]"
