# Old-compiler output

`crime_scene.ink.json` was written by the old inkz serializer (`src/compiler/serializer.zig`), not by
inklecate: it uses a non-standard `{"f(N)": name}` call key. The old compiler's tests compare against it.
Real ink JSON for this story is `test/ground_truth/crime_scene.ink.json`. Delete this directory with
the old compiler (P9.2).
