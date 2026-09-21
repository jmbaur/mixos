# MixOS, a Minimal Nix OS

Not NixOS, but a Nix OS (an OS built with Nix). Uses busybox to the fullest extent to get the smallest possible system.

## Documentation

The documentation can be built by running the following:

```console
$ nix build '.#mixos.manual'
$ xdg-open result/share/doc/mixos/index.html
```

The latest build of docs are hosted [here](https://mixos.jmbaur.com).
