---
title: Anatomy of a Rust for Linux subsystem abstraction
---

This post covers a bit of what I've learned about Rust for Linux and how abstractions around Linux kernel subsystems. Hopefully this will help for anyone else that is trying to add a subsystem abstraction to write drivers in Linux.

## Step 0: Add your bindings

Before we can write abstractions, we need to be able to access the underlying C types and functions to build with.
By default, Rust for Linux model doesn't expose all bindings, and instead, we opt in to building the subsystem of interest. To make the C code available, we need to include the corresponding headers in `rust/bindings/bindings_helper.c`.

```diff
// to rust/bindings/bindings_helper.c
#include <linux/firmware.h>
#include <linux/fs.h>
#include <linux/i2c.h>
+#include <linux/iio/iio.h>
+#include <linux/iio/sysfs.h>
+#include <linux/iio/events.h>
+#include <linux/iio/buffer.h>
+#include <linux/iio/trigger.h>
#include <linux/jiffies.h>
```

### Step 0a: Handle macros and inlines

Any functions and types in the included file are handled by `bindgen` and exported from the `bindings` module. If you see C-code that uses certain functions but can't find the corresponding definition in the `bindings` module, chances are that the function is either a macro or inlined. For example, in the IIO subsystem, you can access private data stored in a IIO device using `iio_priv`.

```c
// definition in linux/iio/iio.h

/* The information at the returned address is guaranteed to be cacheline aligned */
static inline void *iio_priv(const struct iio_dev *indio_dev)
{
 return ACCESS_PRIVATE(indio_dev, priv);
}
```

The `iio_priv` is statically inlined, and won't get output by bindgen by default. To solve this, you can create helpers in C that use those macros or inlined functions, so `bindgen` has something concrete to grab on export. To do this in Rust for Linux, create a C file under `rust/helpers` and include that in `helpers.c`. We must prefix the helper function with `rust_helper_` and `bindgen` will export with the name we want. For example, to access `iio_priv`.
we add `rust/helpers/iio.c`:

```c
// Creating rust/helpers/iio.c with the following code
#include <linux/iio/iio.h>

void *rust_helper_iio_priv(const struct iio_dev *indio_dev) {
    return iio_priv(indio_dev);
}

// and include in `rust/helpers/helpers.c`:

#include "iio.c"
```

Now we can access `bindings::iio_priv` and continue forward.

### Resources

[RFL binding and abstraction docs](https://docs.kernel.org/rust/general-information.html#abstractions-vs-bindings)

## Device registration

For each subsystem, the typical flow is:

1. Allocate device (either yourself or with specific code)
    - Allocate using subsystem code, that gives you a `{subsystem}_dev *` pointer
    - Start from an unitialized, and build out with [`Opaque`](https://rust.docs.kernel.org/kernel/types/struct.Opaque.html)
2. Register the device by itself (`{subsystem}_register_{other}`) or underneath another previously registered device (`devm_..._register`)

### Allocation via subsystem

```rust
struct Registration(bindings::iio_dev);
```

### Allocation with Opaque API

#### Driver examples

- [MiscDeviceRegistration::register](https://rust.docs.kernel.org/src/kernel/miscdevice.rs.html#67)

## Virtual Table and X_ops

Devices will typically contains a reference to a statically allocated virtual table ("vtable"), to allow for passing in device specific behavior for a particular interface. The virtual table contains function pointers and for Rust code to interact with the subsystem, we need to provide compatible function pointers as well. This is usually done with three components:

### Basic Structure

- A trait (`Driver`) that the Rust device and virtual table both implement
  - safe `fn` that use a more ergonomic Rust API to implement the interface
  - has the `#[vtable]` attribute
- A `struct Foo<T: Driver>` which stores the device type `T`
  - This can be the same struct used for registration
- A virtual table `struct Adapter<T>` exposing
  - `unsafe extern "C" fn` with definitions matching the C counterpart
  - associated const (typically `const VTABLE`) filling the C `bar_ops` struct
  - `const fn build` that returns a `&'static bar_ops`

#### Aside: C function pointers

For IIO subsystem devices, the C code expects to have an `iio_info` virtual table which holds all the functions that the driver implements. If you aren't familiar with C function pointers, in the code:

```c
int (*foo)(struct bar *baz);
```

`foo` is a pointer to a function that takes as input a `struct bar*` pointer and returns an integer. The corresponding Rust code would be:

```rust
unsafe extern "C" fn foo(baz: *mut bindings::bar) -> ffi::c_int;
```

### Implementing for `iio`

From the [`iio_info`](https://docs.kernel.org/driver-api/iio/core.html#c.iio_info) documentation, we can see there are many function pointers it can hold. However, typically you only need to implement a few of the functions, and the rest will be set as `NULL`. To know which are needed, you need to read the documentation and find example drivers. Let's fill out the Rust abstraction around this, only for the `read_raw` function pointer.

For the driver:

```rust
#[vtable]
trait Driver {
    fn read_raw(/* TODO Rust types */) -> Result {}
}
```

For the virtual table adapter:

```rust
pub struct Adapter<T: Driver>(PhantomData<T>)

impl<T: Driver> Adapter<T> {
    // int (*read_raw)(struct iio_dev *indio_dev,struct iio_chan_spec const *chan,int *val,int *val2, long mask);
    unsafe extern "C" fn read_raw(
        indio_dev: *mut bindings::iio_dev,
        iio_chan_spec: *const bindings::iio_chan_spec,
        val: *mut ffi::c_int,
        val2: *mut ffi::c_int,
        mask: isize,
    ) -> ffi::c_int {
        // Convert raw pointers to Rust types
        let indio_dev = unsafe {&*indio_dev as IioDevice };
        // ...

        // Use our Rust version on 
        match T::read_raw(indio_dev, ..., mask) {
            Ok(...) => SUCCESS_VALUE, // Not real but however the subsystem expects you to respond
            Err(...) => EINVAL, // kernel::error
        }
    }

    const VTABLE: bindings::iio_info = bindings::iio_info {
        // Because Driver has the #[vtable] attribute, it automatically
        // adds HAS_{FN} associated constants. If the device driver doesn't
        // implement read_raw, HAS_READ_RAW will be false
        read_raw: if T::HAS_READ_RAW {
            Some(Self::read_raw)
        } else {
            None
        },
        // We can initialize the rest to zero
        ..unsafe { MaybeUninit::zeroed().assume_init() }
    };

    // Useful during Registration
    const fn build() -> &'static bindings::iio_info {
        &Self::VTABLE
    }
}
```

## Registering with our vtable

One thing in our registration we need to put everything together is adding the interface we just implemented to the device.
In C code, during intialization but before registration, the device struct will initialize the `*_ops` member to virtual table mapping implemented functions to the expected function pointers.

So during registration, the subsystem driver will do something like

```rust

impl<T: Driver> Registration<T> {
    fn register() {
        let dev: *mut device = /* device initialization */; 
        (*dev).dev_ops = Adapter::<T>::build().as_ptr();
        unsafe { subsystem_register(dev) }
        // etc...
    }
}
```

The magic (in my eyes atleast) here is that for a driver implementation of type `T`, it will

A. `impl Driver`, where we will write our Rust code to implement the subsystem interface
B. Will automatically create a corresponding virtual table, that is statically allocated as runtime, since we have a `const VTABLE`
C. Use `build` to pass a reference the interface we made, during intialization.
D. Any downstream authors using the abstraction, just need to implement the Rust interface and everything else is taken care of

```c
int my_read_raw(
    struct iio_dev *indio_dev,
    struct iio_chan_spec const *chan,
    int *val, int *val2, long mask)
{
    // Implementation
}

struct iio_info my_ops = struct iio_info {
    .read_raw = my_read_raw,
};

void my_register() {
    // ...
    indio_dev->info = &my_ops;
    // ...
}
```

On the rust side:

```rust
struct MyModule(Registration<MyDeviceDriver>);

impl kernel::Module for MyModule {
    fn init(module: &'static ThisModule) -> Result<Self> {
        // ..
        Self(Registration::register())
    }
}

struct MyDeviceDriver;

#[vtable]
impl Device for MyDeviceDriver {
    fn read_raw(/* Rust types */) -> Result {
        // Implementation
    }
}
```

## Oversimplification

Hopefully the above helps give you a decent overview of how abstractions on Linux subsystem abstractions work. There is a heap of things that aren't covered here, but many of the current abstractions have already trodden this path, and handle many of the nuances that are needed. I encourage you to look at the different subsystem abstractions and take notes of what more they do and how that helps the downstream author. Some things to think about

- The `register`, `unregister` and creating some kind of `struct` that holds the device after registration is a super common routine, and several subsystems like `pci` and `drm` use structures and traits from `kernel::driver` like `RegistrationOps` to abstract over this concept. Some subsystems like `miscdevice` don't follow this trend, and have a custom Registration type that doesn't implement `RegistrationOps`. If you had to reimplement `miscdevice` with the RegistrationOps, how would that look, are there tradeoffs?

## Safety, safety, safety

The core strength of Rust, and what makes it valuable for inclusion as a language in the Linux kernel, is the ability to limit or entirely remove ill-defined states. While most subsystems will need to use unsafe code to provide abstractions, if well designed, the investment in a Rust abstraction will pay dividends to all driver authors using that abstraction with less buggy code.

However, if the abstraction contains undefined behavior, then that abstraction will cause more problems than it's worth. Look through the source code of various driver subsystems, and you will find that most unsafe blocks are annotated with comments regarding safety. Whenever you use an unsafe block, be very careful to understand the inputs and context of your code. While not exhaustive, some common trends that people look for:

- I need to use kernel code that takes a `struct device *`, is it possible for me to ever get a null pointer. Is it ok to pass a null pointer to this block?
- I need to access some private data stored in a device, are there other places it could potentially be accessed? A lot of C code will have it in a mutex and lock before doing operations.
- I want to initialize a struct. Are there some members that must be defined, and if not, will the C code, check and add defaults?
- Some resources like subsystem-specific buffers (lets say for instance: *mut bindings::sub_buffer), attached to the device and automatically freed when the device is freed. If I have a wrapper around it (struct Buffer(bindings::sub_buffer)), is is possible in my code to hold a reference (&Buffer) to that after the C code automtically freed it?

## Other random notes

- Bus drivers vs. Device(?)/Higher-level(?) drivers

I have always had trouble understanding these concepts so while maybe not 100% correct it might prove useful to others.
For a given device, typically it will implment a bus driver, think i2c, spi, pci, etc. This layer is at the lower (lowest?) level, connecting the kernel to the underlying hardware. But there are common routines that certain categories of devices, so instead of working at a lower level with the bus drivers, other subsystems have emerged that provide abstractions. The device still needs some bus driver, but it can reuse code from other drivers because it follows the setup. For example, a given temperature sensor with SDA and SCL pins and connecting to a Raspberry Pi, will need to implement the I2C bus driver. On top of that, users of the device will typically want be able to trigger the device to spit out the last 1000 temperature readings within a second. This kind of routine is common across a broad class of sensors, and as a result, there is the IIO subsystem, which provides a unified interface to userspace to perform these types of routines. The IIO subsystem, isn't tied to just the I2C bus driver, since a device could instead connected via SPI or GPIO. So when you implement a device driver, you will implement the bus driver that is needed, along with the IIO subsystem, and maybe more, depending on what features you need.

- Q: I want to implement a Linux subsystem in Rust but don't have the hardware

If you want to implement a subsystem, the easiest way to get a feel for how well your abstraction works (or maybe if it works at all) is to use it to create a driver. However, if you don't have the hardware, it can be difficult to get setup.

One suggestion to look at is to implement a driver that doesn't rely on hardware. This works easiest for higher level subsystems (like iio, regulator, etc.). For examples, in the Linux kernel, look in your subsystem of interest for a "dummy" driver. These will usually have "dummy" in the name, and are helpful for understanding subsystem without having to understand the underlying bus driver.

As mentioned above, you still need some kind of bus driver, even for a software only driver. For IIO, when allocating and registering a device, you need to provide a parent device (ie from the bus driver). In some of the dummy examples, they may use `platform_device` (TODO guessing based on post) or have a custom software bus driver (in IIO there is iio_sw_device). The best way to do this with the most recent kernel is to use the `faux` bus which has abstractions in Rust under `kernel::faux`. This will give you a bus that is simple to use and allows you to play with sofware only driver development. Some examples of how you can use it:

```rust
// Example A: Driver authors use it

struct MyModule {
    fdev: faux::Registration,
    drv: new_subsystem::Device,
}

impl kernel::Module for MyModule {
    fn init(module: &'static ThisModule) -> Result<Self> {
        let fdev = faux::Registration::new(c_str!("faux-module"), None)?;
        let drv = new_subsystem::Device::new(fdev.as_ref(), module)?;
        Self { fdev, drv }
    }
}

// Example A contd
// rust/kernel/new_subsystem.rs
struct Device;
impl Device {
    fn new(device: &Device, module: &'static ThisModule) -> Result<Self> {
        // NOTE: Device::as_raw is a pub(crate) method that gives you a (struct device *)
        unsafe { bindings::new_subsystem_register(device.as_raw(), module.as_ptr()) };
        // ...
    }
}
```

Another option, maybe if the device must always have a parent,

```rust
// rust/kernel/new_subsystem.rs

struct Device<Bus: AsRef<Device>>;

impl<Bus: AsRef<Device>> Device<Bus> {
    fn new(device: &Bus, module: &'static ThisModule) -> Result<Self> {
        // NOTE: Device::as_raw is a pub(crate) method that gives you a (struct device *)
        unsafe { bindings::new_subsystem_register(device.as_ref().as_raw(), module.as_ptr()) };
        // ...
    }
}
// drivers/new_subsystem/my_driver.rs

struct MySoftwareDriver {
    drv: new_subsystem::Device<faux::Registration>,
}

/* rest of the implmentation */
```
