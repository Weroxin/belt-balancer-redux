# Belt Balancer Redux

A Factorio 2.1 mod. Place balancer parts next to each other and they act as one balancer, in whatever shape you build. Belts going into it are inputs, belts coming out are outputs. Every input lane is drawn from equally and every output lane gets an equal share.

Rewrite of Belt Balancer 2. Saves using Belt Balancer 2 carry over: disable it, enable this mod, load the save.

## Development

- `tests/run.sh` runs the headless test scenario against the mod in a throwaway Factorio profile (`tests/run.sh bench` for the benchmark, `SPACE_AGE=1` to enable the DLC). Pass the Factorio executable as the second argument or set `FACTORIO` if it isn't at the default Steam path.
- `graphics/source/balancer.py` renders all sprites and icons with Blender 4.4 (needs Pillow). `--drafts DIR` renders quick previews of every design.

The release zip leaves out `tests/` and `graphics/source/`.

## Credits

Based on Belt Balancer by knoxfighter and Belt Balancer 2 by archiehalliwell and IThundxr. MIT licensed.
