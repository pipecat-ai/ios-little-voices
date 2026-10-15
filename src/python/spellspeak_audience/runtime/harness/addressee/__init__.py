"""The addressee model (released as SpellSpeak Audience): who a line was said to, the player's or a character's.

- `render`: how the single-pass model reads a request (addressee-input-0.1), shared by training and the runtime.
- `features`: the cached-cards model's inputs (addressee-tt-0.5 for rc1, addressee-tt-0.6 for rc2), shared by training and
  the runtime.
- `classifier`: the model at run time, on ONNX Runtime.
- `evidence`: the rules of evidence as code, shared by the data generator and the rules baseline.
- `rules`: the rules baseline, the floor and the harness's instant fallback.
- `bands`: positions and facings to the spatial facts the model reads.
"""
