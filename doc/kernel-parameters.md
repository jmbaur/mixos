# Kernel Parameters {#ch-kernel-parameters}

MixOS reads a few parameters of its own from the kernel command line. They are all spelled `mixos.<name>` in order to disambiguate parameters not meant for any other program.

The command line a kernel boots is left up to the user, since MixOS does not manage any details about boot (e.g. UEFI, FIT image, etc).

## `mixos.self_override` {#sec-kernel-parameters-self-override}

Makes the running `mixos`, stand in for the one in the store, so that the system runs the binary it was booted with rather than the one it was built with. This is mostly helpful for development purposes, to allow for simply carrying a newly built `mixos` through the entire system, and is not needed for normal usage. If you need to change the mixos package itself, use the [dedicated option](#opt-mixos.package).

## `mixos.test_backdoor` {#sec-kernel-parameters-test-backdoor}

Address for `mixos test-backdoor` to listen on. Without it the backdoor guesses the best listen address based on the running environment, for example choosing vsock if in a virtualized environment with a vsock host available.
