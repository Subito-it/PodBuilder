## Beta tool: distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

# PodBuilder

PodBuilder is a complementary tool to [CocoaPods](https://github.com/CocoaPods/CocoaPods) that allows to prebuild pods into frameworks which can then be included into a project’s repo. Instead of committing pod’s source code you add its compiled counterpart. While there is a size penalty in doing so, and some may argue that git isn’t designed to handle large binaries files (check [Git LFS](https://git-lfs.github.com) to overcome that), compilation times will decrease significantly because pod's source files no longer need to be recompiled _very often_. Additionally frameworks contain all architecture so they’re ready to be used both on any device and simulator.

Depending on the size of the project and number of pods this can translate in a significant reduction of compilation times (for a large project we designed this tool for we saw a 5x improvement, but YMMV).

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'pod-builder'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install pod-builder

## Usage

The tool relies on 3 Podfiles

1. _Frameworks/Podfile_ (aka PodBuilder-Podfile): this is your original Podfile. This is still your master Podfile that you will update as needed and is used by PodBuilder to determine which versions and dependencies need to be compiled when prebuilding.
2. _Podfile_ (aka Application-Podfile): this one is based on the one above but will replace precompiled frameworks with references to the local PodBuilder podspec. It is the Podfile used by your app.
3. _Frameworks/Podfile.restore_ (aka Restore-Podfile): this acts as a sort of lockfile and reflects the current state of what is installed in the application, pinning pods to a particular tag or commit. This will be particularly useful until Swift reaches ABI stability, because when you check out an old revision of your code you won't be able to get your project running unless the Swift frameworks were compiled with a same version of Xcode you're currently using.

The nice thing of this setup is that you can quickly switch between the precompiled and the source code version of a pod. In the Application-Podfile the tool will automatically reference to the local podspec for a precompiled pod but will also leave the original source commented. When you need to get source code version you just switch the 2 comments and run `pod install`, for example when you need to debug a pod's internal implementation.

As an example these are the 2 lines that are automatically added to the Application-Podfile:

```ruby
  pod 'PodBuilder/AFNetworking', :path => '../Frameworks'
  # pod 'AFNetworking'
```

### Commands

Podbuilder comes with a set of commands:

- `init`: initializes a project to use PodBuilder
- `deintegrate`: deintegrates PodBuilder's initialization
- `build`: prebuilts a specific pod declared in the PodBuilder-Podfile
- `build_all`: prebuilts all pods declared in the PodBuilder-Podfile
- `restore_all`: rebuilts all pods declared in the Framework/Podfile.restore file
- `install_sources`: installs sources of pods to debug into prebuild frameworks
- `clean`: removes unused prebuilt frameworks, dSYMs and source files added by install_sources

Commands can be run from anywhere in your project's repo that is **required to be under git**. 

#### `init` command

This will sets up a project to use PodBuilder.

The following will happen:

- Create a _Frameworks_ folder in your repo's root.
- Copy your original Podfile to _Frameworks/Podfile_ (PodBuilder-Podfile)
- Add an initially empty _PodBuilder.json_ configuration file
- Modify the original Podfile (Application-Podfile) with some minor customizations

#### `deintegrate` command

This will revert `init`'s changes

#### `build` command

Running `pod_builder build [pod name]` will precompile the pod that should be included in the PodBuilder-Podfile.

The following will happen:

- Create one or more (if there are dependencies) _.framework_ file/s under _Frameworks/Rome_ along with its corresponding _dSYM_ files (if applicable) 
- Update the Application-Podfile replacing the pod definition with the precompiled ones
- Update/create the Podfile.restore (Restore-Podfile)
- Update/create PodBuilder.podspec which is a local podspec for your prebuilt frameworks (more on this later)

#### `build_all` command

As `build` but will prebuild all pods defined in PodBuilder-Podfile.

#### `restore_all` command

Will recompile all pods to the versions defined in the Restore-Podfile.

#### `install_sources` command

When using PodBuilder you loose ability to directly access to the source code of a pod. To overcome this limitation you can use this command which downloads the pod's source code to _Frameworks/Sources_ and with some [tricks](https://medium.com/@t.camin/debugging-prebuilt-frameworks-c9f52d42600b) restores the ability to step into the pods code. This can be very helpful to catch the exact location of a crash when it occurs (showing something more useful than assembly code). It is however advisable to switch to the original pod when doing any advanced debugging during development of code that involves a pod.

#### `clean` command

Deletes all unused files by PodBuilder, including .frameworks, .dSYMs and _Source_ repos.

# Configuration file

_PodBuilder.json_ allows some advanced customizations.

## Supported keys

#### `spec_overrides`

This hash allows to add/replace keys in a podspec specification. This can be useful to solve compilation issue or change compilation behaviour (e.g. compile framework statically by specifying `static_framework = true`) without having to fork the repo.

The key is the pod name, the value a hash with the keys of the podspec that need to be overridden.

As an example here we're setting `module_name` in Google's Advertising SDK:

```json
{
    "spec_overrides": {
        "Google-Mobile-Ads-SDK": {
            "module_name": "GoogleMobileAds"
        }
    }
}
```

#### `build_settings`

Xcode build settings to use. You can override the default values which are:

```json
{
    "ENABLE_BITCODE": "NO",
    "CLANG_ENABLE_MODULE_DEBUGGING": "NO",
    "GCC_OPTIMIZATION_LEVEL": "s",
    "SWIFT_OPTIMIZATION_LEVEL": "-Osize",
    "SWIFT_COMPILATION_MODE": "Incremental"
} 
```

#### `build_system`

Specify which build system to use to compile frameworks. Either `Legacy` (standard build system) or `Latest` (new build system). Default value: `Legacy`.

#### `license_file_name`

PodBuilder will create two license files a plist and a markdown file which contains the licenses of each pod specified in the PodBuilder-Podfile. Defailt value: `Pods-acknowledgements`(plist|md).

#### `skip_licenses`

PodBuilder writes a plist and markdown license files of pods specified in the PodBuilder-Podfile. You can specify pods that should not be included, for example for private pods. 

```json
{
    "skip_licenses": ["Podname1", "Podname2"]
}
```


# Under the hood

PodBuilder leverages CocoaPods code and [cocoapods-rome plugin](https://github.com/CocoaPods/Rome) to compile pods into frameworks. Every compiled framework will be boxed (by adding it as a `vendored_framework`) as a subspec of a local podspec. When needed additional settings will be automatically ported from the original podspec, like for example xcconfig settings.

# FAQ

### **Build failed with longish output to the stdout, what should I do next?**

Relaunch the build command passing `-d`, this won't delete the temporary _/tmp/pod_builder_ folder on failure. Open _/tmp/pod_builder/Pods/Pods.xcproject_, make the Pods-DummyTarget target visible by clicking on _Show_ under _Product->Scheme->Manage shemes..._ and build from within Xcode. This will help you understand what went wrong. Remeber to verify that you're building the _Release_ build configuration.

### **Do I need to commit compiled frameworks?**

No. If the size of compiled frameworks in your repo is a concern you can choose add the _Rome_ and _dSYM_ folder to .gitignore and re-run `pod_builder build_all` locally on every machine.


# Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Subito-it/PodBuilder.


# Caveats
Code isn't probably the cleanest I ever wrote but given the usefulness of the tool I decided to publish it nevertheless.


# Authors
[Tomas Camin](https://github.com/tcamin) ([@tomascamin](https://twitter.com/tomascamin))

# License

The gem is available under the Apache License, Version 2.0. See the LICENSE file for more info.
