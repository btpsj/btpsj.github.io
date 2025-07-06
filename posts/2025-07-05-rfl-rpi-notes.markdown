# RFL notes

Brief development notes on Raspberry Pi, Rust for Linux, etc.

## Setup

Forked 6.16 Linux kernel for Raspberry Pi.

Running 64-bit kernel on RPI Zero 2W

```bash
make ARCH=arm64 LLVM=1 bcm2711_defconfig
make ARCH=arm64 LLVM=1 menuconfig
```

Several debugging options are disabled with recommended config and needed to enable Rust support.
Either turn off module versioning or enable DWARF

To turn on Rust support via enabling DWARF:

1. Activate DWARF
    - Kernel hacking
    - Compile-time checks and compiler options
        - Debug Information
        - Gen DWARF 5
2. Switch module version impl
    - Enable loadable module support
    - Module versioning implementation
        - gendwarfksym

### rust-analyzer

- Generate rust-project.json

```bash
make ARCH=arm64 LLVM=1 rust-analyzer
```

- Add path to VS Code rust-analyzer for discovery

```json
 "rust-analyzer.linkedProjects": [
  "/workspaces/rust-for-linux/rpi-linux/rust-project.json"
 ]
```

## grab i2c abstrations

iio depends on a few other abstractions, such as an interface for i2c/spi/etc.

[List of RFL abstractions](https://github.com/tgross35/RFL-patch-registry) people are working on, in the process
Also search [RFL Zulip](https://rust-for-linux.zulipchat.com/#narrow/channel/291565-Help/topic/.60i2c.60.20and.20.60regmap.60.20modules.3F/with/526965332) and see whats been said

i2c and regmap abstractions on [Fabo repo](https://github.com/Fabo/linux/tree/b4/ncv6336)

### fetch & cherry-pick

```bash
git remote add i2c-upstream https://github.com/Fabo/linux.git
git fetch i2c-upstream b4/ncv6336
```

check commits to figure out the range

cherry pick

```bash
git cherry-pick 0a6740bc99263d21c89944ffcff25dad69907615..06d5c30beee27dadf80356c3ce342235304a3a62
```

patch commits are empty, continue with `git commit --allow-empty`
fix merge errors and `git cherry-pick --continue`

## check it compiles

```bash
make ARCH=arm64 LLVM=1
```

Compile error

```bash
error[E0308]: mismatched types
   --> rust/kernel/regulator/driver.rs:483:28
    |
483 |         unsafe { T::borrow(bindings::rdev_get_drvdata(self.rdev.as_ptr())) }
    |                  --------- ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ expected `*mut <... as ForeignOwnable>::PointedTo`, found `*mut c_void`
    |                  |
    |                  arguments to this function are incorrect
    |
    = note: expected raw pointer `*mut <T as ForeignOwnable>::PointedTo`
               found raw pointer `*mut c_void`
```

Could try to remove regulator, not needed for iio
But try to "fix" it with a reasonable change

Fixing it:
Need to get the pointer types right
Probably just need a cast to the Rust type
Need an example of how to properly use ForeignOwnable and borrow

```bash
$ git grep ForeignOwnable
# Other output
rust/kernel/cpufreq.rs:    types::ForeignOwnable,
# ...
```

Searching around til I find this [block](https://rust.docs.kernel.org/src/kernel/cpufreq.rs.html#634)

```rust
    /// Returns the [`Policy`]'s private data.

    pub fn data<T: ForeignOwnable>(&mut self) -> Option<<T>::Borrowed<'_>> {

        if self.as_ref().driver_data.is_null() {

            None

        } else {

            // SAFETY: The data is earlier set from [`set_data`].

            Some(unsafe { T::borrow(self.as_ref().driver_data.cast()) })

        }

    }
```

There was another compile error about `.cast_mut()`
I saw somewhere on Zulip to just remove it

```bash
error[E0599]: no function or associated item named `init_i2c` found for struct `Regmap` in the current scope
   --> drivers/regulator/ncv6336_regulator.rs:121:47
    |
121 |         let regmap = Arc::new(regmap::Regmap::init_i2c(client, &config)?, GFP_KERNEL)?;
    |                                               ^^^^^^^^ function or associated item not found in `Regmap`

error: aborting due to 1 previous error
```

Relevant code

```rust
impl Regmap {
    #[cfg(CONFIG_REGMAP_I2C = "y")]
    /// Initialize a [`Regmap`] instance for an `i2c` client.
    pub fn init_i2c<T: ConfigOps>(i2c: &i2c::Client, config: &Config<T>) -> Result<Self> {
        // SAFETY: Type invariants guarantee that `i2c.as_raw` is valid and non-null and
        // the Config type invariant guarantee that `config.raw` always contains valid data.
        let regmap = from_err_ptr(unsafe { bindings::regmap_init_i2c(i2c.as_raw(), &config.raw) })?;

        Ok(Regmap(NonNull::new(regmap).ok_or(EINVAL)?))
    }
    // ...
}
```

Find `CONFIG_REGMAP_I2C

Need to reconfigure with CONFIG_REGMAP_I2C

new error

```bash
error[E0425]: cannot find function `regmap_init_i2c` in crate `bindings`
      --> rust/kernel/regmap.rs:77:54
       |
77     |   ...r_ptr(unsafe { bindings::regmap_init_i2c(i2c.as_raw(), &config.raw) })?;
       |                               ^^^^^^^^^^^^^^^ help: a function with a similar name exists: `__regmap_init_i2c`
       |
      ::: /workspaces/rust-for-linux/rpi-linux/rust/bindings/bindings_generated.rs:110163:5
       |
110163 | /     pub fn __regmap_init_i2c(
110164 | |         i2c: *mut i2c_client,
110165 | |         config: *const regmap_config,
110166 | |         lock_key: *mut lock_class_key,
110167 | |         lock_name: *const ffi::c_char,
110168 | |     ) -> *mut regmap;
       | |_____________________- similarly named function `__regmap_init_i2c` defined here

error: aborting due to 1 previous error
```

macro issue with bindgen it seems
in `<linux/regmap.h>` regmap_init_i2c is defined as a macro that automatically fills out `lock_key` and `lock_name`

```c
#define regmap_init_i2c(i2c, config)     \
 __regmap_lockdep_wrapper(__regmap_init_i2c, #config,  \
    i2c, config)
```

lockdep macro

```c
/*
 * Wrapper for regmap_init macros to include a unique lockdep key and name
 * for each call. No-op if CONFIG_LOCKDEP is not set.
 *
 * @fn: Real function to call (in the form __[*_]regmap_init[_*])
 * @name: Config variable name (#config in the calling macro)
 **/
#ifdef CONFIG_LOCKDEP
#define __regmap_lockdep_wrapper(fn, name, ...)    \
(         \
 ({        \
  static struct lock_class_key _key;   \
  fn(__VA_ARGS__, &_key,     \
   KBUILD_BASENAME ":"    \
   __stringify(__LINE__) ":"   \
   "(" name ")->lock");    \
 })        \
)
#else
#define __regmap_lockdep_wrapper(fn, name, ...) fn(__VA_ARGS__, NULL, NULL)
#endif
```

`bindgen` seems to have an issue with this macro, and doesn't output anything into `bindings_generated.rs`
It seems like it should have worked as others have used the tree before
From the implementation of the macro, seems like we can pass `NULL` for now

```diff
-#if IS_BUILTIN(CONFIG_REGMAP_I2C)
+// #if IS_BUILTIN(CONFIG_REGMAP_I2C)
 struct regmap *rust_helper_regmap_init_i2c(struct i2c_client *i2c,
                                           const struct regmap_config *config)
 {
-       return regmap_init_i2c(i2c, config);
+       return __regmap_init_i2c(i2c, config, NULL, NULL);
 }
-#endif
+// #endif
```

Not sure about the IS_BUILTIN, so I turned it off to avoid config issues for now
Switch to __regmap_init_i2c implementation
I thought the rust_helper_XXX needs to shadow something called XXX in bindings, but seems like it doesn't matter
and will happily define something new, which is nice

Recompile and everything compiles fine

## Figure out what else is needed

Count the includes in drivers/iio

```bash
$ python count_includes.py | sort -n -r
591 linux/module.h # Yes, kernel::Module
540 linux/iio/iio.h # Needed
289 linux/mod_devicetable.h # maybe? module_device_table! macro, and device_id for implementing subsystem-specific table
253 linux/delay.h # Needed
251 linux/iio/sysfs.h # Needed
247 linux/regmap.h # Just added
241 linux/i2c.h # Just added
239 linux/kernel.h # Yes?
198 linux/device.h # Yes
197 linux/regulator/consumer.h # Just added
196 linux/iio/buffer.h # Needed
196 linux/err.h # Yes, kernel::error
180 linux/interrupt.h # Needed
179 linux/spi/spi.h # Later
169 linux/slab.h # Kind of? krealloc available through kernel::alloc::allocator, not sure if that is all is needed
166 linux/iio/trigger_consumer.h # Needed
164 linux/iio/triggered_buffer.h # Needed
```

### Potential drivers to reco-implement

"Simple" drivers that have few includes, so an easier API surface to covert

```bash
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/chemical/sen0322.c
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/chemical/ens160_spi.c
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/chemical/ens160_i2c.c
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/chemical/bme680_i2c.c
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/adc/xilinx-xadc-events.c
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/accel/mma7455_spi.c
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/accel/mma7455_i2c.c
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/accel/adxl345_spi.c
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/accel/adxl345_i2c.c
3       /workspaces/rust-for-linux/rpi-linux/drivers/iio/accel/adxl313_core.c
2       /workspaces/rust-for-linux/rpi-linux/drivers/iio/pressure/mpl115_spi.c
2       /workspaces/rust-for-linux/rpi-linux/drivers/iio/pressure/mpl115_i2c.c
2       /workspaces/rust-for-linux/rpi-linux/drivers/iio/magnetometer/rm3100-spi.c
2       /workspaces/rust-for-linux/rpi-linux/drivers/iio/magnetometer/rm3100-i2c.c
2       /workspaces/rust-for-linux/rpi-linux/drivers/iio/dac/ad5696-i2c.c
2       /workspaces/rust-for-linux/rpi-linux/drivers/iio/dac/ad5686-spi.c
1       /workspaces/rust-for-linux/rpi-linux/drivers/iio/test/iio-test-format.c
```

- MPL115a2
  - I have one
  - /workspaces/rust-for-linux/rpi-linux/drivers/iio/pressure/mpl115_i2c.c
    - Relatively small
    - also SPI version
  - Needs pm_runtime
    - Power Management runtime
    - Putting devices to sleep

- Dummy SW IIO
  - No hardware, probably best to start here
    - Includes

    ```c
    #include <linux/iio/iio.h>
    #include <linux/iio/sysfs.h>
    #include <linux/iio/events.h>
    #include <linux/iio/buffer.h>
    #include <linux/iio/sw_device.h>
    #include "iio_simple_dummy.h"
    ```
